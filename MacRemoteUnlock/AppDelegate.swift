import Cocoa
import Security
import IOKit.pwr_mgt
import ApplicationServices

// Wake the display so keystrokes can be injected into the lock screen.
func wakeDisplay() {
    var assertionID: IOPMAssertionID = 0
    IOPMAssertionDeclareUserActivity("MacRemoteUnlock" as CFString, kIOPMUserActiveLocal, &assertionID)
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let remote = RemoteUnlockServer()
    let mainMenu = NSMenu()
    let remoteMenu = NSMenu()
    var remoteURLLabel: NSMenuItem?
    var funnelURLLabel: NSMenuItem?
    var funnelToggleItem: NSMenuItem?
    var funnelOpenItem: NSMenuItem?
    var launchAtLoginItem: NSMenuItem?
    var showTokenItem: NSMenuItem?
    var lockToggleItem: NSMenuItem?

    /// Whether the access token is shown in the menu. Default OFF (safer).
    var showTokenInMenu: Bool {
        get { UserDefaults.standard.bool(forKey: "showTokenInMenu") }
        set { UserDefaults.standard.set(newValue, forKey: "showTokenInMenu") }
    }

    var displaySleep = false
    var systemSleep = false
    var inScreensaver = false
    var unlockedAt = 0.0

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        if menu == remoteMenu {
            let ips = remote.tailscaleIPs()
            let host = ips.first ?? "not connected to Tailscale"
            if showTokenInMenu {
                remoteURLLabel?.title = "http://\(host):\(remote.port)/  token: \(remote.token)"
            } else {
                remoteURLLabel?.title = "http://\(host):\(remote.port)/"
            }
            showTokenItem?.state = showTokenInMenu ? .on : .off
            lockToggleItem?.state = remote.lockScreenEnabled ? .on : .off
            if let url = remote.funnelURL {
                funnelURLLabel?.title = "Funnel: \(url)"
            } else if remote.funnelEnabled {
                funnelURLLabel?.title = "Funnel: starting…"
            } else {
                funnelURLLabel?.title = "Funnel: disabled"
            }
            funnelToggleItem?.state = remote.funnelEnabled ? .on : .off
            funnelOpenItem?.isHidden = !remote.funnelEnabled
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "MacRemoteUnlock")
            constructMenu()
        }

        remote.currentLocked = { [weak self] in
            self?.isScreenLocked() ?? false
        }
        remote.onApprove = { [weak self] in
            var message = "unlock approved"
            DispatchQueue.main.sync {
                message = self?.remoteUnlock() ?? "unlock approved"
            }
            return message
        }
        remote.lockedState = isScreenLocked()
        if remote.enabled {
            remote.start()
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onScreenLocked), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onUnlock), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        checkAccessibility()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if remote.enabled && remote.funnelEnabled {
            print("Remote: app terminating, disabling funnel")
            remote.disableFunnelSync()
        }
    }

    // MARK: - Lock state notifications

    @objc func onScreenLocked() {
        print("screen locked")
        remote.lockedState = true
    }

    @objc func onUnlock() {
        remote.lockedState = false
    }

    @objc func onDisplayWake() {
        print("display wake")
        displaySleep = false
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("system wake")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            self.systemSleep = false
        })
    }

    @objc func onSystemSleep() {
        print("system sleep")
        systemSleep = true
    }

    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
    }

    func log(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let dir = NSHomeDirectory() + "/Library/Logs/MacRemoteUnlock"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir + "/unlock.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    // MARK: - Unlock

    func remoteUnlock() -> String {
        guard isScreenLocked() else { return "Mac 未处于锁定状态" }
        guard let password = fetchPassword(warn: false) else { return "未设置密码（菜单：Set Login Password…）" }
        log("unlock approved; state locked=\(isScreenLocked()) displaySleep=\(displaySleep) systemSleep=\(systemSleep) inScreensaver=\(inScreensaver)")
        if displaySleep {
            wakeAndUnlock(password)
        } else {
            // Locked with the display on (screensaver remote-lock path).
            // Wait for the lock screen to settle, then type —
            // performRemoteUnlock handles Esc to exit the screensaver.
            // (A sleep/wake cycle is not needed here: the screensaver lock
            // path has proper keyboard focus on the login window.)
            log("locked, display on: waiting 1.2s then typing")
            Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false, block: { [weak self] _ in
                self?.performRemoteUnlock(password)
            })
        }
        return "已批准，正在输入密码…"
    }

    private func wakeAndUnlock(_ password: String) {
        wakeDisplay()
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            attempts += 1
            if !self.displaySleep || attempts >= 12 {
                t.invalidate()
                if !self.displaySleep {
                    // Give the login window time to fully appear after wake
                    // — injecting while it is still coming up makes every
                    // keystroke beep and get dropped.
                    self.log("display awake; waiting 2s for login window to settle")
                    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false, block: { [weak self] _ in
                        self?.performRemoteUnlock(password)
                    })
                }
            } else {
                wakeDisplay()
            }
        })
    }

    private func sleepDisplayNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        do {
            try p.run()
        } catch {
            log("sleepDisplayNow failed: \(error)")
        }
    }

    /// Click just above the centre of the main display to focus the login
    /// (needed when the screen is locked but not asleep).
    func clickScreenCenter() {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let p = CGPoint(x: bounds.midX, y: bounds.midY - bounds.height * 0.12)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Select-all + Delete in the password field, so leftover characters from
    /// a previous failed attempt can't corrupt the next injection. Harmless
    /// when the field is empty.
    func clearPasswordField() {
        let src = CGEventSource(stateID: .hidSystemState)
        let aDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)  // 0 = A
        aDown?.flags = .maskCommand
        aDown?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)  // 51 = delete
        CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Click the lock-screen password field so it takes keyboard focus.
    /// First tries the Accessibility API to read the field's real coordinates
    /// (position only, not content). Falls back to the known layout spot
    /// (~72-80% screen height, confirmed by user testing).
    func clickPasswordField() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let p = findPasswordFieldCenter() {
            log("AX located password field at \(p)")
            let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
            let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(150_000)
            return
        }
        log("AX did not locate password field; using fallback positions")
        let bounds = CGDisplayBounds(CGMainDisplayID())
        for fy in [0.72, 0.76, 0.80] {
            let p = CGPoint(x: bounds.midX, y: bounds.height * fy)
            let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
            let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(150_000)
        }
    }

    /// Search the loginwindow Accessibility tree for the password field and
    /// return its centre point in screen coordinates. Reads geometry only.
    func findPasswordFieldCenter() -> CGPoint? {
        guard let loginwindow = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.loginwindow"
        }) else { return nil }
        let app = AXUIElementCreateApplication(loginwindow.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let winList = windows as? [AXUIElement] else { return nil }
        for win in winList {
            if let p = searchPasswordField(in: win) { return p }
        }
        return nil
    }

    private func searchPasswordField(in el: AXUIElement) -> CGPoint? {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
           let r = role as? String, r == "AXSecureTextField",
           let p = fieldCenter(of: el) {
            return p
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
           let kids = children as? [AXUIElement] {
            for k in kids {
                if let p = searchPasswordField(in: k) { return p }
            }
        }
        return nil
    }

    private func fieldCenter(of el: AXUIElement) -> CGPoint? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        let p = pos as! AXValue
        let s = size as! AXValue
        var point = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &sz) else { return nil }
        return CGPoint(x: point.x + sz.width / 2, y: point.y + sz.height / 2)
    }

    func performRemoteUnlock(_ password: String, retries: Int = 3) {
        guard isScreenLocked() else {
            log("performRemoteUnlock skipped, not locked anymore")
            return
        }
        log("performing unlock, inScreensaver=\(inScreensaver) displaySleep=\(displaySleep) locked=\(isScreenLocked())")
        if inScreensaver {
            log("pressing Esc to exit screensaver")
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x35, keyDown: false)?.post(tap: .cghidEventTap)
            // Give the screensaver time to exit and the login window to appear.
            Thread.sleep(forTimeInterval: 0.8)
        }
        print("Remote: sending password keystrokes")
        unlockedAt = Date().timeIntervalSince1970
        clickPasswordField()
        Thread.sleep(forTimeInterval: 0.4)  // let the click land and focus
        clearPasswordField()
        Thread.sleep(forTimeInterval: 0.2)  // let the field clear before typing
        fakeKeyStrokes(password)
        log("keystrokes sent")
        // The keystrokes may have raced the lock screen settling. If still
        // locked shortly after, retry — just re-type (no click, which would
        // steal focus from the password field).
        if retries > 0 {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false, block: { [weak self] _ in
                guard let self = self else { return }
                if self.isScreenLocked() {
                    self.log("still locked, retrying (retries left: \(retries - 1))")
                    self.performRemoteUnlock(password, retries: retries - 1)
                } else {
                    self.log("unlocked")
                }
            })
        }
    }

    // MARK: - Key events

    func fakeKeyStrokes(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Send 20 characters per keyboard event (seems to be the limit)
        let PER = 20
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex
        for offset in stride(from: 0, to: uniCharCount, by: PER) {
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)
            let len = offset + PER < uniCharCount ? PER : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }

        // Return key
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }

    // MARK: - Keychain

    func storePassword(_ password: String) {
        let pw = password.data(using: .utf8)!
        let service = Bundle.main.bundleIdentifier ?? "MacRemoteUnlock"

        // Remove any existing item first
        let deleteQuery: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Use kSecAttrAccessible (NOT kSecAttrAccessControl):
        // - AfterFirstUnlock: readable after a reboot once the keychain is
        //   unlocked (survives system restarts).
        // - No access-control object: the item's ACL stays "allow all
        //   applications", so it does NOT get bound to our ad-hoc code
        //   signature. With an access-control object, every rebuild changes
        //   the signature and macOS prompts for keychain access again
        //   (which fails silently while the screen is locked).
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): service,
            String(kSecAttrLabel): "MacRemoteUnlock",
            String(kSecAttrAccessible): kSecAttrAccessibleAfterFirstUnlock,
            String(kSecValueData): pw,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            let err = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to store password to Keychain", info: err as String? ?? "Status \(status)")
            return
        }
        // Explicitly set the item's ACL to "any application". The default ACL
        // binds to the creating app's signature and macOS re-prompts for
        // access after a reboot — which fails silently while the screen is
        // locked. A nil-path trusted application means "any app, no prompt".
        if let item = copyKeychainItem(service) {
            setAccessAnyApp(item)
        }
    }

    private func copyKeychainItem(_ service: String) -> SecKeychainItem? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): service,
            String(kSecReturnRef): kCFBooleanTrue!,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let ref = item else { return nil }
        return (ref as! SecKeychainItem)
    }

    // Deprecated (macOS 10.15+) but still functional; the only way to set an
    // explicit "allow any application" ACL on a keychain item.
    private func setAccessAnyApp(_ item: SecKeychainItem) {
        var app: SecTrustedApplication?
        SecTrustedApplicationCreateFromPath(nil, &app)  // nil path = any application
        guard let trusted = app else { return }
        let list = [trusted] as CFArray
        var access: SecAccess?
        guard SecAccessCreate("MacRemoteUnlock" as CFString, list, &access) == errSecSuccess,
              let a = access else { return }
        SecKeychainItemSetAccess(item, a)
    }

    func fetchPassword(warn: Bool = false) -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): Bundle.main.bundleIdentifier ?? "MacRemoteUnlock",
            String(kSecReturnData): kCFBooleanTrue!,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            print("Password is not stored")
            if warn {
                errorModal("Password not set. Use Set Password… in the menu.")
            }
            return nil
        }
        guard status == errSecSuccess else {
            if status == errSecInteractionNotAllowed {
                // Keychain not accessible right now (e.g. screen locked / keychain locked).
                // No point showing a modal dialog while locked.
                print("Password read blocked (keychain locked, err -25308)")
                return nil
            }
            let info = SecCopyErrorMessageString(status, nil)
            errorModal("Failed to retrieve password", info: info as String? ?? "Status \(status)")
            return nil
        }
        guard let data = item as? Data else {
            errorModal("Failed to convert password")
            return nil
        }
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Menu actions

    @objc func toggleShowToken(_ item: NSMenuItem) {
        showTokenInMenu = !showTokenInMenu
        item.state = showTokenInMenu ? .on : .off
    }

    @objc func toggleRemoteLock(_ item: NSMenuItem) {
        remote.lockScreenEnabled = !remote.lockScreenEnabled
        item.state = remote.lockScreenEnabled ? .on : .off
    }

    @objc func toggleRemoteFunnel(_ item: NSMenuItem) {
        let on = !remote.funnelEnabled
        remote.funnelEnabled = on
        item.state = on ? .on : .off
        funnelOpenItem?.isHidden = !on
        print("Remote: funnel \(on ? "enabled" : "disabled")")
    }

    @objc func openRemotePage() {
        if let url = URL(string: "http://127.0.0.1:\(remote.port)/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openFunnelPage() {
        if remote.funnelURL == nil {
            remote.setupFunnelIfNeeded() // kick off (re)configuration
            errorModal("Funnel 正在配置中，请稍后重试。若仍未生效，请检查 Tailscale 连接。")
            return
        }
        guard let urlString = remote.funnelURL, let url = URL(string: urlString) else {
            errorModal("Funnel URL 无效")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func setRemoteToken() {
        let msg = NSAlert()
        msg.addButton(withTitle: "OK")
        msg.addButton(withTitle: "Cancel")
        msg.messageText = "Set Access Token"
        msg.informativeText = "至少 6 位（数字和字母均可）。手机浏览器解锁时需输入此令牌。"
        msg.window.title = "MacRemoteUnlock"
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        txt.stringValue = remote.token
        msg.accessoryView = txt
        NSApp.activate(ignoringOtherApps: true)
        if msg.runModal() == .alertFirstButtonReturn {
            let v = txt.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.count >= 6 {
                remote.token = v
            } else {
                errorModal("Token must be at least 6 characters")
            }
        }
    }

    @objc func setRemotePort() {
        let msg = NSAlert()
        msg.addButton(withTitle: "OK")
        msg.addButton(withTitle: "Cancel")
        msg.messageText = "Set HTTP Server Port"
        msg.window.title = "MacRemoteUnlock"
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        txt.stringValue = String(remote.port)
        msg.accessoryView = txt
        NSApp.activate(ignoringOtherApps: true)
        if msg.runModal() == .alertFirstButtonReturn {
            let v = Int(txt.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if v > 0 && v < 65536 {
                remote.port = UInt16(v)
                if remote.enabled {
                    remote.stop()
                    remote.start()
                }
            } else {
                errorModal("Invalid port")
            }
        }
    }

    @objc func askPassword() {
        let msg = NSAlert()
        msg.addButton(withTitle: "OK")
        msg.addButton(withTitle: "Cancel")
        msg.messageText = "Set Login Password"
        msg.informativeText = "Stored in your Keychain. Used to unlock the screen when you approve from your phone."
        msg.window.title = "MacRemoteUnlock"
        let txt = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        if msg.runModal() == .alertFirstButtonReturn {
            storePassword(txt.stringValue)
        }
    }

    // MARK: - Launch at login (LaunchAgent, no helper app / signing required)

    private func launchAgentPath() -> String {
        NSHomeDirectory() + "/Library/LaunchAgents/github.dongyuwei.macremoteunlock.plist"
    }

    func isLaunchAtLogin() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath())
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let path = launchAgentPath()
        if enabled {
            let plist: [String: Any] = [
                "Label": "github.dongyuwei.macremoteunlock",
                "ProgramArguments": [Bundle.main.executablePath ?? ""],
                "RunAtLoad": true,
            ]
            (plist as NSDictionary).write(toFile: path, atomically: true)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    @objc func toggleLaunchAtLogin(_ item: NSMenuItem) {
        let on = !isLaunchAtLogin()
        setLaunchAtLogin(on)
        item.state = on ? .on : .off
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "MacRemoteUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            // Actually trying to send a key may open the Accessibility dialog too
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Menu construction

    func constructMenu() {
        let remoteItem = mainMenu.addItem(withTitle: "Remote Unlock", action: nil, keyEquivalent: "")
        remoteItem.submenu = remoteMenu
        remoteMenu.delegate = self

        remoteURLLabel = remoteMenu.addItem(withTitle: "not started", action: nil, keyEquivalent: "")
        funnelURLLabel = remoteMenu.addItem(withTitle: "Funnel: disabled", action: nil, keyEquivalent: "")
        funnelToggleItem = remoteMenu.addItem(withTitle: "Enable Funnel (public URL)", action: #selector(toggleRemoteFunnel), keyEquivalent: "")
        funnelToggleItem?.state = remote.funnelEnabled ? .on : .off
        funnelOpenItem = remoteMenu.addItem(withTitle: "Open Unlock Page (Funnel)…", action: #selector(openFunnelPage), keyEquivalent: "")
        funnelOpenItem?.isHidden = !remote.funnelEnabled
        remoteMenu.addItem(withTitle: "Open Unlock Page…", action: #selector(openRemotePage), keyEquivalent: "")
        remoteMenu.addItem(withTitle: "Set Access Token…", action: #selector(setRemoteToken), keyEquivalent: "")
        showTokenItem = remoteMenu.addItem(withTitle: "Show Access Token", action: #selector(toggleShowToken), keyEquivalent: "")
        showTokenItem?.state = showTokenInMenu ? .on : .off
        remoteMenu.addItem(withTitle: "Set HTTP Server Port…", action: #selector(setRemotePort), keyEquivalent: "")
        lockToggleItem = remoteMenu.addItem(withTitle: "Enable Remote Lock Screen", action: #selector(toggleRemoteLock), keyEquivalent: "")
        lockToggleItem?.state = remote.lockScreenEnabled ? .on : .off

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: "Set Login Password…", action: #selector(askPassword), keyEquivalent: "")
        launchAtLoginItem = mainMenu.addItem(withTitle: "Launch At Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem?.state = isLaunchAtLogin() ? .on : .off
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = mainMenu
    }
}
