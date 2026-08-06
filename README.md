# MacRemoteUnlock

一个极简的 macOS 菜单栏 App：当 Mac 锁屏时，通过手机浏览器（Tailscale 私网或公网 Funnel）批准，Mac 自动输入登录密码解锁。

A minimal macOS menu bar app: when your Mac is locked, approve it from a phone browser (over Tailscale or the public Funnel URL) and it types your login password to unlock.

这是 [BLEUnlock](https://github.com/ts1/BLEUnlock) 的**远程解锁精简版**（fork），剥离了蓝牙接近检测、媒体控制等无关功能。
This is a **remote-unlock-only fork** of [BLEUnlock](https://github.com/ts1/BLEUnlock), stripped of Bluetooth proximity detection, media control, etc.

## 初衷 / Motivation

作者日常使用 Mac 时，Touch ID 识别失败率较高——尤其是**冬季干燥**时指纹更难识别；且本人**指纹较浅**，经常需要输密码。加上比较懒不想每次敲密码，于是做了这个 app：锁屏后，手机点一下「批准解锁」，Mac 自动输入密码登录。

The author's Mac Touch ID frequently fails to recognize the fingerprint — especially in **dry winter** conditions, and the fingerprints are **shallow**, so typing the password was needed often. Being too lazy to type it every time, this app was made: when the Mac is locked, tap **approve** on the phone and the Mac types the password and logs in.

## 功能 / Features

- 轻量 HTTP server（POSIX socket，无第三方依赖），默认端口 8123 / Lightweight HTTP server (POSIX sockets, no dependencies), default port 8123
- **Tailscale 网段限制**：只接受 `100.64.0.0/10` 或 `localhost` 来源，其余 403 / **Tailscale source restriction**: only accepts `100.64.0.0/10` or `localhost`, everything else gets 403
- **6 位数字 token** + **失败限速**（5 次错误锁 60 秒，暴力破解不可行）/ **6-digit token** + **rate limiting** (5 failures → 60s lockout)
- **Tailscale Funnel**（可选，默认关闭）：一键发布公网 HTTPS 地址，手机无需装 Tailscale / **Tailscale Funnel** (optional, default off): one-click public HTTPS URL, no Tailscale needed on the phone
- 密码存在 **Keychain**，绝不离开 Mac；手机只发送"批准"信号 / Password stored in **Keychain**, never leaves the Mac; the phone only sends an approve signal
- **默认启用** remote unlock / Remote unlock is **enabled by default**
- **Start at Login** 选项（LaunchAgent，无需 helper app）/ **Start at Login** option (LaunchAgent, no helper app required)

## 构建与运行 / Build & Run

```sh
# 首次：构建并启动 / first time: build and start
./start.sh --build
# 之后：启动（自动杀掉旧实例）/ afterwards: start (kills any existing instance)
./start.sh
```

日志 / Log: `~/Library/Logs/MacRemoteUnlock/macremoteunlock.log`

## 首次使用 / First-time Setup

1. 启动后（remote unlock **默认启用**），菜单栏图标 → **Remote Unlock** 查看地址和 token
   After launch (remote unlock is **enabled by default**), menu bar icon → **Remote Unlock** to see the URL and token
2. **Set Login Password…** 设置一次登录密码（存入 Keychain）/ set your login password once (stored in Keychain)
3. 授予**辅助功能权限**：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 MacRemoteUnlock
   Grant **Accessibility** permission: System Settings → Privacy & Security → Accessibility → enable MacRemoteUnlock
   （没有该权限时，批准后键盘注入会被系统拦截，Mac 不会解锁 / without it, keystroke injection is blocked and unlock silently fails）
4. 手机浏览器访问菜单里显示的地址（`http://<tailscale-ip>:8123/`），输入 6 位 token
   Open the URL shown in the menu (`http://<tailscale-ip>:8123/`) on your phone browser and enter the 6-digit token
5. 锁屏 Mac → 手机页面点「批准解锁」→ Mac 自动输入密码解锁
   Lock the Mac → tap **approve** on the phone → the Mac types the password and unlocks

## 公网访问（可选，默认关闭）/ Public Access (optional, default off)

菜单 → **Enable Funnel (public URL)**：
Menu → **Enable Funnel (public URL)**:

- app 自动执行 `tailscale funnel --bg 8123`，生成公网 HTTPS 地址（如 `https://<机器名>.<tailnet>.ts.net`）
  The app runs `tailscale funnel --bg 8123` and publishes a public HTTPS URL (e.g. `https://<machine>.<tailnet>.ts.net`)
- 手机浏览器直接访问该地址，**无需安装 Tailscale** / open it in any browser, **no Tailscale needed**
- 关闭/退出时自动停用 Funnel / Funnel is disabled on toggle-off or app quit
- ⚠️ Funnel 暴露公网，务必保留 6 位 token（限速已内置）/ ⚠️ Funnel exposes the service publicly — keep the 6-digit token (rate limiting is built in)

## 与 BLEUnlock 的关系 / Relationship to BLEUnlock

**感谢 / Credits**: [BLEUnlock](https://github.com/ts1/BLEUnlock) by Takeshi Sone (MIT). 本项目基于它的核心机制精简而来。

**复用的代码 / Reused code**（from BLEUnlock）:
- Keychain 密码存取（`storePassword`/`fetchPassword`）/ Keychain password storage (`storePassword`/`fetchPassword`)
- CGEvent 键盘注入解锁（`fakeKeyStrokes`）、锁屏检测（`isScreenLocked`）、唤醒屏幕与屏保处理（`wakeDisplay`、Esc 退出屏保）
  CGEvent keystroke injection (`fakeKeyStrokes`), lock detection (`isScreenLocked`), display wake and screensaver handling (`wakeDisplay`, Esc to exit screensaver)
- 菜单栏状态栏 UI 结构 / menu bar status item structure

> 注：`RemoteUnlockServer.swift`（HTTP server、Tailscale 来源限制、6 位 token、失败限速、Funnel 自动配置）是**本项目开发中编写**的，不属于 BLEUnlock 原始代码。
> Note: `RemoteUnlockServer.swift` (HTTP server, Tailscale source restriction, 6-digit token, rate limiting, Funnel auto-configuration) was **written for this project**, not part of the original BLEUnlock.

**移除的功能 / Removed**: BLE 接近检测（BLE.swift）、RSSI 菜单、媒体暂停恢复（MediaRemote）、登录项 Launcher helper、AboutBox、更新检查、lock/unlock 事件脚本。

## 已知限制 / Known Limitations

- 仅覆盖**锁屏场景**（重启后登录窗口 / FileVault 界面需手动输密码）
  Works only for the **lock screen** (login window after reboot / FileVault still need a manual password)
- Debug 构建是 ad-hoc 签名，辅助功能授权绑定启动路径：**必须用 `./start.sh` 启动**，复制到 /Applications 会静默失去解锁权限；重新构建后如失效需重新授权
  Debug builds are ad-hoc signed; the Accessibility permission is bound to the launch path — **always launch via `./start.sh`**, copying to /Applications silently loses the permission; re-grant it after rebuilding

## License

MIT，与 BLEUnlock 一致。见 [LICENSE](LICENSE)。
MIT, same as BLEUnlock. See [LICENSE](LICENSE).

## 安全性 / Security

安全模型、威胁分析与最佳实践见 [SECURITY.md](SECURITY.md)。
Threat model, defense layers and best practices: [SECURITY.md](SECURITY.md).
