# MacRemoteUnlock

一个极简的 macOS 菜单栏 App：当 Mac 锁屏时，通过手机浏览器（Tailscale 私网或公网 Funnel）批准，Mac 自动输入登录密码解锁。

从 BLEUnlock 剥离出的精简版，**只保留远程解锁功能**（无蓝牙接近检测、无媒体控制等）。

## 功能

- 轻量 HTTP server（POSIX socket，无第三方依赖），默认端口 8123
- **Tailscale 网段限制**：只接受 `100.64.0.0/10` 或 `localhost` 来源，其余 403
- **6 位数字 token** + **失败限速**（5 次错误锁 60 秒，暴力破解不可行）
- **Tailscale Funnel**（可选，默认关闭）：一键发布公网 HTTPS 地址，手机无需装 Tailscale
- 密码存在 **Keychain**，绝不离开 Mac；手机只发送"批准"信号
- 菜单栏显示连接地址/token/Funnel 状态，可随时切换

## 构建与运行

```sh
# 首次：构建并启动
./start.sh --build
# 之后：启动（自动杀掉旧实例）
./start.sh
```

日志：`~/Library/Logs/MacRemoteUnlock/macremoteunlock.log`

## 首次使用

1. 启动后，菜单栏图标 → **Remote Unlock** → 勾选 **Enable Remote Unlock**
2. **Set Password…** 设置一次登录密码（存入 Keychain）
3. 授予**辅助功能权限**：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 MacRemoteUnlock
   （没有该权限时，批准后键盘注入会被系统拦截，Mac 不会解锁）
4. 手机浏览器访问菜单里显示的地址（`http://<tailscale-ip>:8123/`），输入 6 位 token
5. 锁屏 Mac → 手机页面点「批准解锁」→ Mac 自动输入密码解锁

## 公网访问（可选，默认关闭）

菜单 → **Enable Funnel (public URL)**：
- app 自动执行 `tailscale funnel --bg 8123`，生成公网 HTTPS 地址（如 `https://<机器名>.<tailnet>.ts.net`）
- 手机浏览器直接访问该地址，**无需安装 Tailscale**
- 关闭/退出时自动停用 Funnel
- ⚠️ Funnel 暴露公网，务必保留 6 位 token（限速已内置）

## 与 BLEUnlock 的关系

- **保留**：HTTP server、token 认证、Funnel、Keychain 密码、CGEvent 注入解锁、限速
- **移除**：BLE 接近检测、RSSI 菜单、媒体暂停恢复、登录项 Launcher、AboutBox、更新检查、事件脚本

## 已知限制

- 仅覆盖**锁屏场景**（重启后登录窗口 / FileVault 界面需手动输密码）
- 与 BLEUnlock **共用 8123 端口**，两者不能同时运行（先退出一方）
- Debug 构建是 ad-hoc 签名，辅助功能授权绑定启动路径：**必须用 `./start.sh` 启动**，复制到 /Applications 会静默失去解锁权限；重新构建后如失效需重新授权

## License

MIT（继承自 BLEUnlock，Copyright © Takeshi Sone）
