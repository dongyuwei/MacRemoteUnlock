# 安全性说明 / Security

MacRemoteUnlock 可以远程解锁你的 Mac（敏感操作），安全性是设计的核心。本文档说明威胁模型、防御分层、已知边界和建议。

MacRemoteUnlock can remotely unlock your Mac (a sensitive operation); security is central to its design. This document covers the threat model, defense layers, known boundaries and recommendations.

---

## 威胁模型 / Threat model

**防御的目标 / Defended against**:
- Tailscale 网络上的陌生人（理论上可扫描到你设备的 100.x 地址）/ strangers on the Tailscale network who could scan your devices
- 扫描到 Funnel 公网 URL 的陌生人 / strangers who find your public Funnel URL
- 知道 token 但无权使用你的 Mac 的人 / someone who knows the token but has no right to your Mac

**不在防御范围内的前提假设 / Out of scope (assumptions)**:
- 已登录你的 Mac、能读你本机文件的人——本来就能解锁 Mac 或读取 Keychain / anyone already logged into your Mac or able to read local files can already unlock it or read the Keychain
- 持有**已解锁**手机的人——token 是第二道门，但手机本身是信任边界 / someone holding your **unlocked** phone — the token is a second gate, but the phone itself is a trust boundary

## 防御分层 / Defense in depth

| 层 / Layer | 机制 / Mechanism | 说明 / Notes |
|---|---|---|
| 网络隔离 / Network isolation | Tailscale 私网（CGNAT 100.64.0.0/10） | 默认只接受 `100.64.0.0/10` 或 `localhost` 来源；公网（Funnel）需**显式开启** / by default only accepts `100.64.0.0/10` or `localhost`; public exposure (Funnel) must be explicitly enabled |
| 来源校验 / Source check | 服务端检查远端 IP | 非 Tailscale 来源直接 `403`（握手都到不了时由系统防火墙兜底）/ non-Tailscale sources get `403` (if the connection never reaches the server, the OS firewall handles it) |
| 认证 / Authentication | 6 位数字 token | `/status` `/approve` `/deny` 必须携带，错误或缺失返回 `401` / required on protected endpoints, wrong/missing gets `401` |
| 暴力防护 / Brute-force protection | 失败限速 | 连续 5 次失败锁定 60 秒（`429`），每次失败响应延迟 1 秒 → 穷举全部 100 万组合需数月 / 5 consecutive failures → 60s lockout (`429`), each failure delayed 1s → brute-forcing all 1M combinations takes months |
| 密码保护 / Password protection | Keychain | 登录密码**只存 Mac Keychain，绝不通过网络传输**；手机只发送"批准"信号 / password never leaves the Mac; the phone only sends an approve signal |

## Funnel 公网暴露 / Public exposure via Funnel

- Funnel（`tailscale funnel --bg`）把服务发布为公网 HTTPS URL，**默认关闭**，需在菜单显式开启 / publishes the service at a public HTTPS URL, **off by default**, enabled from the menu
- 风险：任何知道 URL 的人都能发起请求，只能靠 token + 限速挡住 / risk: anyone with the URL can send requests — only the token + rate limit stand in the way
- 缓解：默认关闭；6 位 token；失败限速；建议定期轮换 token / mitigations: off by default, 6-digit token, rate limiting, rotate the token regularly
- 关闭方式：菜单取消勾选，或 `tailscale funnel --https=443 off` / disable from the menu or `tailscale funnel --https=443 off`

## WebAuthn 指纹认证评估 / WebAuthn evaluation

曾评估用 WebAuthn（浏览器调用手机系统指纹）替代 token，**结论：暂缓** / We evaluated replacing the token with WebAuthn (browser-driven phone fingerprint auth); **decision: deferred**.

- 技术可行：Tailscale Funnel 已提供受信任 HTTPS，满足 WebAuthn 的 secure context 前提 / feasible — Funnel provides trusted HTTPS, satisfying WebAuthn's secure-context requirement
- 安全增量小：攻击者拿到手机后必须先过手机锁屏；WebAuthn 只是把"解锁手机"换成"解锁手机 + 指纹" / marginal security gain — an attacker must pass the phone lock screen anyway; WebAuthn only adds "fingerprint on top of unlocked phone"
- 体验差：每次批准都要弹指纹框 / worse UX: a fingerprint prompt on every approve
- 若未来需要，路线已明确：Funnel(HTTPS) + WebAuthn 平台认证器 + CryptoKit 验签 / if ever needed, the path is clear: Funnel(HTTPS) + platform authenticator + CryptoKit verification

## 已知边界 / Known boundaries

- **token 明文存储**：存于 `UserDefaults`（`~/Library/Preferences/github.dongyuwei.macremoteunlock.plist`）。可接受——能读本机文件的人本就可解锁 Mac / token stored in plaintext in UserDefaults — acceptable, since anyone with local file access could unlock the Mac anyway
- **6 位数字空间 100 万**：单靠 token 不够强，必须配合网络隔离与限速 / 1M combinations — never rely on the token alone; network isolation and rate limiting are required
- **限速是内存状态**：app 重启后计数清零 / rate-limit counters are in-memory and reset on app restart
- **模拟输入**：批准后 Mac 用 CGEvent 注入输入密码，等价于你自己输密码，不是 Touch ID / approval types the password via CGEvent injection, equivalent to typing it yourself, not Touch ID
- **锁屏场景**：仅覆盖锁屏（会话存活）；重启后登录窗口 / FileVault 界面需手动输密码 / lock-screen only; login window after reboot / FileVault still need a manual password

## 建议 / Recommendations

- **定期轮换 token**（菜单：Set Access Token）/ rotate the token regularly (menu: Set Access Token)
- **Funnel 不用时保持关闭**；公网访问后随手关闭 / keep Funnel off when not needed; disable it after public use
- 手机保持**锁屏密码/生物识别** / keep the phone locked with a passcode/biometrics
- 不要分享 Funnel URL / don't share the Funnel URL
- 密码变更后重新设置（Set Login Password）/ re-set the password after changing it (Set Login Password)
