#!/bin/bash
# MacRemoteUnlock 重启后诊断脚本
# 重启后如发现远程解锁不工作，运行本脚本，把输出发出来即可定位环节。
# Run this after a reboot if remote unlock stops working, then share the output.

echo "========== MacRemoteUnlock 诊断 =========="
echo

echo "=== 1. app 进程 ==="
if pgrep -fl "MacRemoteUnlock.app/Contents/MacOS" > /dev/null; then
    pgrep -fl "MacRemoteUnlock.app/Contents/MacOS" | head -1
    echo "   ✅ app 在运行"
else
    echo "   ❌ app 未运行（检查 Launch At Login 是否勾选，或手动 ./start.sh）"
fi
echo

echo "=== 2. HTTP 服务端口 8123 ==="
if lsof -nP -iTCP:8123 -sTCP:LISTEN 2>/dev/null | grep -q MacRemote; then
    echo "   ✅ 8123 在监听"
else
    echo "   ❌ 8123 未监听（app 未启动或 server 启动失败）"
fi
echo

echo "=== 3. HTTP 页面响应 ==="
CODE=$(curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:8123/ 2>/dev/null)
echo "   HTTP $CODE"
[ "$CODE" = "200" ] && echo "   ✅ 页面可访问" || echo "   ❌ 页面不可访问"
echo

echo "=== 4. Keychain 密码读取状态 ==="
TMPDIR_D=$(mktemp -d)
cat > "$TMPDIR_D/main.swift" << 'EOF'
import Foundation
import Security
let q: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: NSUserName(),
    kSecAttrService as String: "github.dongyuwei.macremoteunlock",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
]
var item: AnyObject?
let st = SecItemCopyMatching(q as CFDictionary, &item)
switch st {
case errSecSuccess: print("SUCCESS (0) 能读到密码")
case errSecItemNotFound: print("NOT FOUND (-25300) 条目不存在")
case errSecInteractionNotAllowed: print("INTERACTION NOT ALLOWED (-25308) keychain 锁定/不可交互")
case errSecAuthFailed: print("AUTH FAILED (-25293) ACL 拒绝")
default: print("错误码 \(st)")
}
EOF
if swiftc -o "$TMPDIR_D/kc" "$TMPDIR_D/main.swift" 2>/dev/null; then
    RESULT=$("$TMPDIR_D/kc")
    echo "   $RESULT"
    case "$RESULT" in
        SUCCESS*) echo "   ✅ Keychain 正常" ;;
        *) echo "   ❌ Keychain 读不到（这就是原因）" ;;
    esac
else
    echo "   （测试编译失败，跳过）"
fi
rm -rf "$TMPDIR_D"
echo

echo "=== 5. 辅助功能（Accessibility/TCC）授权 ==="
TCCDB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
AUTH=$(sqlite3 "$TCCDB" "SELECT client, auth_value FROM access WHERE service='kTCCServiceAccessibility' AND client LIKE '%MacRemoteUnlock%';" 2>/dev/null)
if [ -n "$AUTH" ]; then
    echo "   记录: $AUTH  (auth_value: 2=允许, 0=拒绝)"
    echo "$AUTH" | grep -q "|2" && echo "   ✅ 已授权" || echo "   ❌ 授权状态异常（auth_value != 2）"
else
    echo "   （TCC 数据库无法读取或没有记录。请在 系统设置→隐私与安全性→辅助功能 查看 MacRemoteUnlock 是否勾选）"
fi
echo

echo "=== 6. Launch At Login 配置 ==="
if launchctl list 2>/dev/null | grep -q macremote; then
    echo "   ✅ LaunchAgent 已加载"
else
    echo "   ❌ LaunchAgent 未加载"
fi
echo
echo "========== 结束 =========="
