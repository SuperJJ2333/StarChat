# 公网域名统一 API 网关验证证据

日期：2026-08-18

## 设计与计划

- 规格：`docs/superpowers/specs/2026-08-18-public-domain-api-gateway-design.md`
- 计划：`docs/superpowers/plans/2026-08-18-public-domain-api-gateway.md`

## 测试先行证据

- 网关策略测试首次失败于缺少 `business_api_upstream`，实现主域、www、admin 和 Synapse Admin 拒绝规则后通过。
- 生产配置契约测试首次失败于缺少 `WWW_PUBLIC_HOSTNAME`，补充环境样例和移动发布命令后通过。
- 公网验收脚本结构测试首次失败于脚本不存在，实现 DNS、TLS、重定向、Business API、Matrix、well-known 和管理边界检查后通过。

## 当前公网基线

- `liuhetong888.com`、`www.liuhetong888.com`、`admin.liuhetong888.com` 均解析到 `207.56.8.8`。
- HTTP 主域和 www 当前返回 `502`，没有按批准规则跳转。
- 三个域名的 HTTPS 请求均无法建立受信任 TLS 连接。
- Business API、Matrix、well-known 和 admin 公网检查因此失败。
- `scripts/verify_public_domains.ps1`：`FAIL (13 checks)`。

## 远端部署通道

- `207.56.8.8:22` TCP 可连接，且主机已存在于本机 known_hosts。
- 已发现历史 SSH 用户名为 `root`，但 BatchMode 连接被远端立即关闭，当前没有可用的非交互授权会话。
- 未猜测密码、未修改远端 SSH 设置、未开放临时端口。

当前远端上线状态：`BLOCKED`。解除条件是提供已授权的 SSH/部署代理会话，并在服务器安装覆盖三个域名的受信任证书。

## Flutter 域名版制品

- 构建入口：`scripts/build_mobile_public_domain.ps1`。
- URL 策略测试拒绝 HTTP、localhost、IPv4 literal、局域网 IP 和带 `/api/v1` 的根地址；批准的 `https://liuhetong888.com` 通过。
- Release APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-release.apk`。
- Release 大小：136,098,612 bytes。
- Release SHA-256：`7BCF034AD077C9D1E2BF22B6CCB56A5444948B65E906A44DE79094C3058608D7`。
- Release APK 已注入 Business API 与 Matrix 的 `https://liuhetong888.com` 编译参数。
- Release 覆盖安装被 Android 以 `INSTALL_FAILED_UPDATE_INCOMPATIBLE` 拒绝，因为模拟器现有验收包使用 Debug 签名；未卸载应用，避免删除本地 E2EE 数据。
- Debug 域名验收 APK：241,977,499 bytes，SHA-256 `7FAA3E5129154AC05F6A240AD6BE92BC6CE87B789C4CB20D2E950D0055F0DEBB`。
- Debug 域名验收 APK 使用相同 Debug 签名覆盖安装到 `emulator-5554`：`Success`。

由于公网 TLS 和网关尚未上线，当前仅验证制品构建、签名边界与安装，不把真实登录标记为通过。
