import Foundation
import Darwin

// Remote Unlock HTTP Server (prototype)
//
// - Lightweight HTTP/1.1 server built on POSIX sockets (no third-party deps)
// - Listens on all interfaces on a configurable port (default 8123)
// - ONLY accepts requests whose source IP is in the Tailscale CGNAT range
//   (100.64.0.0/10) or localhost (for local testing)
// - Requires a 6-digit numeric token for status/approve endpoints
// - Browser page polls /status and calls /approve to unlock the Mac
//
// The login password never leaves the Mac: the phone only sends an "approve"
// signal, and the Mac types its own Keychain-stored password.

final class RemoteUnlockServer {

    private let prefs = UserDefaults.standard

    // MARK: - Rate limiting (brute-force protection)

    private let maxFailedAttempts = 5
    private let lockoutDuration: TimeInterval = 60
    private let failureDelay: TimeInterval = 1.0
    private let rateLock = NSLock()
    private var failedAttempts = 0
    private var lockUntil: Date?

    private func isRateLimited() -> Bool {
        rateLock.lock(); defer { rateLock.unlock() }
        if let until = lockUntil {
            if Date() < until { return true }
            lockUntil = nil
            failedAttempts = 0
        }
        return false
    }

    private func registerFailure() {
        rateLock.lock(); defer { rateLock.unlock() }
        failedAttempts += 1
        if failedAttempts >= maxFailedAttempts {
            lockUntil = Date().addingTimeInterval(lockoutDuration)
            failedAttempts = 0
            print("RemoteUnlock: rate limit triggered, locked until \(lockUntil!)")
        }
    }

    private func resetFailures() {
        rateLock.lock(); defer { rateLock.unlock() }
        failedAttempts = 0
        lockUntil = nil
    }

    // MARK: - State (thread-safe)

    private let lockStateQueue = DispatchQueue(label: "RemoteUnlockLockState")
    private var _locked = false
    var lockedState: Bool {
        get { lockStateQueue.sync { _locked } }
        set { lockStateQueue.sync { _locked = newValue } }
    }

    // Called when the Mac wants to know the CURRENT lock state (used on every /status)
    var currentLocked: (() -> Bool)?

    // Called when an approved unlock request arrives. Returns a human-readable result message.
    var onApprove: (() -> String)?

    // MARK: - Server lifecycle

    private var listenFD: Int32 = -1
    private var serverRunning = false
    private let serverQueue = DispatchQueue(label: "RemoteUnlockServer", qos: .userInitiated)

    /// Public Tailscale Funnel URL (https://<machine>.<tailnet>.ts.net), resolved after start.
    private(set) var funnelURL: String?

    /// Whether Tailscale Funnel (public internet exposure) is enabled.
    /// Default OFF. Turning it on starts funnel; turning it off stops it.
    var funnelEnabled: Bool {
        get { prefs.bool(forKey: "remoteFunnelEnabled") }
        set {
            prefs.set(newValue, forKey: "remoteFunnelEnabled")
            if newValue {
                setupFunnelIfNeeded()
            } else {
                disableFunnelSync()
            }
        }
    }

    // MARK: - Configuration

    var enabled: Bool {
        get {
            // Default ON: enabled unless the user explicitly turned it off.
            if prefs.object(forKey: "remoteUnlockEnabled") == nil { return true }
            return prefs.bool(forKey: "remoteUnlockEnabled")
        }
        set {
            prefs.set(newValue, forKey: "remoteUnlockEnabled")
            if newValue { start() } else { stop() }
        }
    }

    var port: UInt16 {
        get {
            let p = prefs.integer(forKey: "remotePort")
            return p > 0 ? UInt16(p) : 8123
        }
        set { prefs.set(Int(newValue), forKey: "remotePort") }
    }

    /// Access token: at least 6 characters (digits and/or letters, case-sensitive).
    /// Auto-generated on first access.
    var token: String {
        get {
            if let t = prefs.string(forKey: "remoteToken"), t.count >= 6 {
                return t
            }
            let t = Self.randomToken()
            prefs.set(t, forKey: "remoteToken")
            return t
        }
        set { prefs.set(newValue, forKey: "remoteToken") }
    }

    private static func randomToken() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }

    func start() {
        guard !serverRunning else { return }
        serverRunning = true
        serverQueue.async { self.serverLoop() }
        if funnelEnabled {
            setupFunnelIfNeeded()
        } else {
            cleanupFunnelIfOurs()
        }
    }

    /// If Funnel is enabled in tailscaled but proxies OUR port (a leftover from
    /// an earlier run), close it so "default off" is actually off.
    /// Never touches configs that proxy other ports.
    private func cleanupFunnelIfOurs() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let cli = self.findTailscaleCLI() else { return }
            guard let status = self.run(cli, ["serve", "status"]) else { return }
            let target = "127.0.0.1:\(self.port)"
            if status.contains(target), status.lowercased().contains("funnel on") {
                _ = self.run(cli, ["funnel", "--https=443", "off"])
                print("RemoteUnlock: closed leftover funnel proxying \(target)")
            }
        }
    }

    func stop() {
        serverRunning = false
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) } // interrupts blocking accept()
    }

    // MARK: - Tailscale Funnel

    /// Disable Tailscale Funnel (called synchronously on app termination so the
    /// public endpoint is closed before the process exits).
    func disableFunnelSync() {
        guard let cli = findTailscaleCLI() else { return }
        if let out = run(cli, ["funnel", "--https=443", "off"]) {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("RemoteUnlock: funnel off: \(trimmed)")
            }
        }
        funnelURL = nil
    }

    /// Enable `tailscale funnel` for the server port and resolve the public
    /// ts.net URL (https://<machine>.<tailnet>.ts.net). Runs async, idempotent.
    func setupFunnelIfNeeded() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let url = self.enableFunnel(port: self.port)
            DispatchQueue.main.async {
                self.funnelURL = url
                if let url = url {
                    print("RemoteUnlock: Funnel URL: \(url)")
                } else {
                    print("RemoteUnlock: Funnel not configured")
                }
            }
        }
    }

    private func enableFunnel(port: UInt16) -> String? {
        guard let cli = findTailscaleCLI() else {
            print("RemoteUnlock: tailscale CLI not found; skipping funnel")
            return nil
        }

        // If an existing serve/funnel config is present, make sure it points at
        // OUR current port. Otherwise the new 'funnel --bg' would fail with
        // "listener already exists for port 443" and the proxy would keep the
        // old port (which happens after the user changes the HTTP server port).
        if let status = run(cli, ["serve", "status"]) {
            let target = "127.0.0.1:\(port)"
            let hasFunnel = status.lowercased().contains("funnel on") || status.contains("ts.net")
            if hasFunnel {
                if status.contains(target) {
                    print("RemoteUnlock: funnel already configured for port \(port)")
                } else {
                    print("RemoteUnlock: funnel points elsewhere, resetting and re-pointing to port \(port)")
                    run(cli, ["serve", "reset"])
                }
            }
        }

        // Idempotent: make sure funnel is on for this port (background mode = persistent)
        if let out = run(cli, ["funnel", "--bg", String(port)]) {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("RemoteUnlock: tailscale funnel: \(trimmed)")
            }
        }
        // Resolve the machine's ts.net DNS name
        guard let status = run(cli, ["status", "--json"]),
              let dns = dnsName(fromJSON: status) else {
            print("RemoteUnlock: could not resolve ts.net DNS name")
            return nil
        }
        let host = dns.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "https://\(host)"
    }

    private func findTailscaleCLI() -> String? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "\(NSHomeDirectory())/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(_ cli: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("RemoteUnlock: failed to run \(cli): \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func dnsName(fromJSON status: String) -> String? {
        let pattern = "\"DNSName\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: status, range: NSRange(status.startIndex..., in: status)) else {
            return nil
        }
        let nsRange = match.range(at: 1)
        guard let r = Range(nsRange, in: status) else { return nil }
        return String(status[r])
    }

    // MARK: - Accept loop

    private func serverLoop() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("RemoteUnlock: socket() failed, errno=\(errno)")
            serverRunning = false
            return
        }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: 0) // INADDR_ANY: listen on all interfaces (incl. Tailscale)

        let bindRes = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s -> Int32 in
                bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            print("RemoteUnlock: bind failed on port \(port), errno=\(errno)")
            close(fd)
            serverRunning = false
            return
        }
        guard listen(fd, 16) == 0 else {
            print("RemoteUnlock: listen failed, errno=\(errno)")
            close(fd)
            serverRunning = false
            return
        }

        listenFD = fd
        print("RemoteUnlock: listening on port \(port)")

        while serverRunning {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &storage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { s -> Int32 in
                    accept(fd, s, &len)
                }
            }
            if clientFD >= 0 {
                Thread.detachNewThread { self.handle(clientFD) }
            }
        }

        close(fd)
        listenFD = -1
        serverRunning = false
    }

    // MARK: - Request handling (minimal HTTP/1.1, one request per connection)

    private func handle(_ clientFD: Int32) {
        defer { close(clientFD) }

        // 5s read timeout so a stuck client can't hold a thread forever
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = Data()
        var temp = [UInt8](repeating: 0, count: 8192)
        while buf.count < 65536 {
            let n = read(clientFD, &temp, temp.count)
            if n > 0 {
                buf.append(contentsOf: temp[0..<n])
                if buf.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            } else {
                break // EOF or timeout
            }
        }

        guard let headerRange = buf.range(of: Data("\r\n\r\n".utf8)) else {
            send(clientFD, status: 400, body: json(["error": "Bad Request"]))
            return
        }
        let header = String(data: buf.subdata(in: buf.startIndex..<headerRange.lowerBound), encoding: .utf8) ?? ""
        let bodyData = buf.subdata(in: headerRange.upperBound..<buf.endIndex)

        var contentLength = 0
        for line in header.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1)
                contentLength = value.count == 2 ? (Int(value[1].trimmingCharacters(in: .whitespaces)) ?? 0) : 0
            }
        }
        let body = String(data: bodyData.prefix(contentLength), encoding: .utf8) ?? ""

        process(clientFD, header: header, body: body)
    }

    private func process(_ fd: Int32, header: String, body: String) {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            send(fd, status: 400, body: json(["error": "Bad Request"])); return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            send(fd, status: 400, body: json(["error": "Bad Request"])); return
        }
        let method = parts[0]
        let rawTarget = parts[1]

        // Parse path + query
        var path = rawTarget
        var query: [String: String] = [:]
        if let qIndex = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<qIndex])
            let qs = String(rawTarget[rawTarget.index(after: qIndex)...])
            for kv in qs.split(separator: "&") {
                let pair = kv.split(separator: "=", maxSplits: 1)
                if pair.count == 2 {
                    query[String(pair[0])] = String(pair[1]).removingPercentEncoding ?? String(pair[1])
                }
            }
        }

        // --- Source IP restriction: Tailscale CGNAT (100.64.0.0/10) or localhost ---
        guard let remoteIP = peerIP(fd) else {
            send(fd, status: 403, body: json(["error": "cannot determine source IP"])); return
        }
        guard isAllowedSource(remoteIP) else {
            print("RemoteUnlock: blocked request from \(remoteIP)")
            send(fd, status: 403, body: json(["error": "forbidden: not a Tailscale address"])); return
        }

        // --- Token check (except for GET / which serves the page itself) ---
        let reqToken = (query["token"] ?? headerValue(header, name: "X-Auth-Token"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenOK = (reqToken == token.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokenProtected = (path == "/status" || path == "/approve" || path == "/deny")

        if tokenProtected {
            if isRateLimited() {
                send(fd, status: 429, body: json(["error": "too many attempts, try again later"]))
                return
            }
            if !tokenOK {
                registerFailure()
                Thread.sleep(forTimeInterval: failureDelay) // slow down brute force
                send(fd, status: 401, body: json(["error": "invalid token"]))
                return
            }
            resetFailures()
        }

        switch (method, path) {
        case ("GET", "/"):
            send(fd, status: 200, contentType: "text/html; charset=utf-8",
                 body: htmlPage(macName: macName()))

        case ("GET", "/status"):
            guard tokenOK else {
                send(fd, status: 401, body: json(["error": "invalid token"])); return
            }
            let lockedNow = currentLocked?() ?? lockedState
            send(fd, status: 200, contentType: "application/json",
                 body: json([
                    "locked": lockedNow,
                    "mac": macName(),
                    "now": Int(Date().timeIntervalSince1970),
                 ]))

        case ("POST", "/approve"):
            guard tokenOK else {
                send(fd, status: 401, body: json(["error": "invalid token"])); return
            }
            let message = onApprove?() ?? "approved"
            send(fd, status: 200, contentType: "application/json",
                 body: json(["ok": true, "message": message]))

        case ("POST", "/deny"):
            guard tokenOK else {
                send(fd, status: 401, body: json(["error": "invalid token"])); return
            }
            print("RemoteUnlock: unlock request denied")
            send(fd, status: 200, contentType: "application/json",
                 body: json(["ok": true, "message": "已拒绝"]))

        default:
            send(fd, status: 404, body: json(["error": "not found"]))
        }
    }

    // MARK: - Socket helpers

    private func send(_ fd: Int32, status: Int, contentType: String = "application/json", body: String) {
        let header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        let data = header.data(using: .utf8)! + body.data(using: .utf8)!
        data.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, data.count)
        }
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        default: return "Status"
        }
    }

    private func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func headerValue(_ header: String, name: String) -> String? {
        for line in header.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix(name.lowercased() + ":") {
                let value = line.split(separator: ":", maxSplits: 1)
                if value.count == 2 {
                    return value[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private func macName() -> String {
        Host.current().localizedName ?? Host.current().name ?? "Mac"
    }

    /// Extract the remote IPv4 address of a connected socket.
    private func peerIP(_ fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { s -> Int32 in
                getpeername(fd, s, &len)
            }
        }
        guard result == 0 else { return nil }

        if storage.ss_family == sa_family_t(AF_INET) {
            let addr = withUnsafePointer(to: &storage) { ptr -> sockaddr_in in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            var str = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = addr.sin_addr
            inet_ntop(AF_INET, &sinAddr, &str, socklen_t(str.count))
            return String(cString: str)
        }
        if storage.ss_family == sa_family_t(AF_INET6) {
            // IPv4-mapped IPv6 (::ffff:a.b.c.d)
            let addr6 = withUnsafePointer(to: &storage) { ptr -> sockaddr_in6 in
                ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            }
            let bytes = withUnsafeBytes(of: addr6.sin6_addr.__u6_addr) { Array($0.bindMemory(to: UInt8.self)) }
            if bytes.count == 16
                && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0
                && bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0 && bytes[7] == 0
                && bytes[8] == 0 && bytes[9] == 0 && bytes[10] == 0xFF && bytes[11] == 0xFF {
                return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
            }
            return nil
        }
        return nil
    }

    /// Tailscale uses CGNAT range 100.64.0.0/10 (100.64.0.0 – 100.127.255.255).
    private func isAllowedSource(_ ip: String) -> Bool {
        if ip == "127.0.0.1" || ip == "::1" { return true } // local testing
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
    }

    /// Enumerate this Mac's Tailscale IPv4 addresses (100.64.0.0/10).
    func tailscaleIPs() -> [String] {
        var addrs: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let interface = p.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if isAllowedSource(ip) {
                        addrs.append(ip)
                    }
                }
            }
            ptr = interface.ifa_next
        }
        freeifaddrs(first)
        return addrs
    }

    // MARK: - Web page

    private func htmlPage(macName: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <title>Mac 远程解锁</title>
        <style>
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        body {
          margin: 0; min-height: 100vh;
          background: #0f1115;
          display: flex; align-items: center; justify-content: center;
          font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
          color: #e8eaed;
        }
        .card {
          width: 92%; max-width: 400px;
          background: #1a1d24; border-radius: 16px;
          padding: 28px 24px; text-align: center;
          box-shadow: 0 8px 30px rgba(0,0,0,.5);
        }
        .icon { font-size: 64px; line-height: 1; margin-bottom: 12px; }
        .mac { font-size: 15px; color: #9aa0a6; margin-bottom: 20px; }
        h1 { font-size: 22px; margin: 0 0 8px; font-weight: 600; }
        .state { font-size: 15px; color: #9aa0a6; margin-bottom: 20px; min-height: 20px; }
        button {
          display: block; width: 100%;
          padding: 16px; font-size: 18px; font-weight: 600;
          border: none; border-radius: 12px; cursor: pointer;
          margin-top: 8px;
        }
        .approve { background: #34a853; color: #fff; }
        .approve:active { background: #2e8e48; }
        .approve:disabled { background: #2a3a2f; color: #7f8c84; }
        .secondary { background: #2a2f38; color: #e8eaed; margin-top: 12px; font-size: 15px; }
        input[type=password] {
          width: 100%; padding: 14px; font-size: 24px; letter-spacing: 8px; text-align: center;
          border: 1px solid #3a4150; border-radius: 12px; background: #14171d; color: #fff;
        }
        .msg { margin-top: 14px; font-size: 14px; min-height: 18px; color: #fbbc04; }
        .err { color: #f28b82; margin-top: 10px; font-size: 14px; }
        .ok { color: #81c995; }
        .hint { margin-top: 14px; font-size: 12px; color: #5f6368; }
        </style>
        </head>
        <body>
        <div class="card">
          <div class="icon" id="icon">⏳</div>
          <h1>\(macName)</h1>
          <div class="mac">远程解锁</div>
          <div class="state" id="state">连接中…</div>
          <div id="actionArea"></div>
          <div class="msg" id="msg"></div>
          <div class="hint" id="hint"></div>
        </div>
        <script>
        var TOKEN_KEY = 'bleunlock_token';
        var token = localStorage.getItem(TOKEN_KEY) || '';
        var pollTimer = null;

        function setIcon(icon) { document.getElementById('icon').textContent = icon; }
        function setState(s) { document.getElementById('state').textContent = s; }
        function setMsg(s, cls) {
          var m = document.getElementById('msg');
          m.textContent = s || '';
          m.className = 'msg' + (cls ? ' ' + cls : '');
        }

        function showTokenInput() {
          clearInterval(pollTimer); pollTimer = null;
          setIcon('🔐');
          setState('请输入访问令牌');
          document.getElementById('actionArea').innerHTML =
            '<input type="password" autocomplete="off" maxlength="32" ' +
            'placeholder="至少 6 位（数字/字母）" id="tokenInput">' +
            '<button class="approve" onclick="submitToken()" style="margin-top:14px">验证</button>';
          document.getElementById('hint').textContent = '';
          setMsg('');
          var inp = document.getElementById('tokenInput');
          inp.focus();
          inp.addEventListener('keydown', function(e) { if (e.key === 'Enter') submitToken(); });
        }

        function submitToken() {
          var v = document.getElementById('tokenInput').value.trim();
          if (v.length < 6) { setMsg('请输入至少 6 位数字或字母', 'err'); return; }
          token = v;
          localStorage.setItem(TOKEN_KEY, token);
          setMsg('');
          startPolling();
        }

        function startPolling() {
          document.getElementById('actionArea').innerHTML = '';
          setMsg('');
          clearInterval(pollTimer);
          pollTimer = setInterval(poll, 2000);
          poll();
        }

        function renderLocked() {
          setIcon('🔒');
          setState('Mac 已锁定');
          document.getElementById('actionArea').innerHTML =
            '<button class="approve" id="approveBtn" onclick="approve()">批准解锁</button>' +
            '<button class="secondary" onclick="refresh()">刷新状态</button>';
          document.getElementById('hint').textContent = '仅在你本人准备使用 Mac 时批准';
        }

        function renderUnlocked() {
          setIcon('🔓');
          setState('Mac 未锁定');
          document.getElementById('actionArea').innerHTML =
            '<button class="secondary" onclick="refresh()">刷新状态</button>';
          document.getElementById('hint').textContent = '';
        }

        function renderOffline() {
          setIcon('📡');
          setState('无法连接 Mac');
          document.getElementById('actionArea').innerHTML =
            '<button class="secondary" onclick="startPolling()">重试</button>';
          document.getElementById('hint').textContent = '请检查 Tailscale 连接';
        }

        function renderRateLimited() {
          setIcon('⏱️');
          setState('尝试次数过多');
          document.getElementById('actionArea').innerHTML =
            '<button class="secondary" onclick="refresh()">重试</button>';
          document.getElementById('hint').textContent = '请 1 分钟后再试';
          clearInterval(pollTimer);
          pollTimer = setInterval(poll, 10000); // slow polling; auto-recovers when lockout ends
        }

        async function poll() {
          try {
            var r = await fetch('/status?token=' + encodeURIComponent(token));
            if (r.status === 429) { renderRateLimited(); return; }
            if (r.status === 401) {
              localStorage.removeItem(TOKEN_KEY);
              showTokenInput();
              setMsg('令牌无效，请重新输入', 'err');
              return;
            }
            if (!r.ok) { renderOffline(); return; }
            var d = await r.json();
            if (d.locked) renderLocked(); else renderUnlocked();
          } catch (e) {
            renderOffline();
          }
        }

        function refresh() { clearInterval(pollTimer); startPolling(); }

        async function approve() {
          var btn = document.getElementById('approveBtn');
          btn.disabled = true; btn.textContent = '处理中…';
          setMsg('');
          try {
            var r = await fetch('/approve?token=' + encodeURIComponent(token), { method: 'POST' });
            var d = await r.json();
            if (r.status === 429) {
              setMsg('尝试次数过多，请 1 分钟后再试', 'err');
              return;
            }
            setMsg(d.message || (r.ok ? '已批准' : '请求失败'), r.ok ? 'ok' : 'err');
          } catch (e) {
            setMsg('网络错误', 'err');
          }
          btn.disabled = false; btn.textContent = '批准解锁';
        }

        if (token && token.length >= 6) {
          startPolling();
        } else {
          showTokenInput();
        }
        </script>
        </body>
        </html>
        """
    }
}
