# Android 正式版 0.3.67 / 2070 发布记录

日期：2026-09-09。用户明确授权发布 Android 更新，iOS 暂不发布。

## 发布结果

- 源码提交：`8d404d1f020b46d4f6deeacf2b6059446d273dcc`，分支 `codex/redmi-polish-20260909`。
- 包名 `com.liuhetong.mobile`，版本 `0.3.67`，构建号 `2070`，ARM64 release，最低 Android API 24。
- 下载：[ChatFlow-0.3.67-build2070-arm64.apk](https://www.liuhetong888.com/downloads/ChatFlow-0.3.67-build2070-arm64.apk)。
- 文件大小：77,010,443 字节。
- SHA256：`b37b7155aeb1389231b5decab6860ac441e604541f14377b5bf35f4165fd128d`。
- 沿用固定发行签名，证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；v2/v3 验签通过。
- 最低支持构建号保持 `3`，未提高强制升级门槛。
- `latest-arm64.apk` 已原子切换至该版本；旧版 `ChatFlow-0.3.54-build56-arm64.apk` 保留。

## 构建与校验

依照 `docs/runbooks/android-apk-rebuild.md`，从隔离工作树执行 Flutter standard release ARM64 源码构建，再用 Apktool 2.12.1 完整重建 DEX、资源及 Manifest，完成 16K 对齐和固定签名。原始 Flutter APK 仅作为中间产物。

初次 `--no-pub` 构建复用了 Debug 的 integration_test 插件注册文件而失败；重新执行正常 pub 流程后 release 构建通过，未手工修改注册器。源码及最终产物通过发行检查，最终 Manifest 不含 debuggable 标志。重建前后 24,573 个类语义一致，337 个原生库/资产条目无变化，Manifest 语义一致，资源与五个 DEX 完成重建。

本地最终包、服务器暂存包、服务器公网完整下载、本机公网完整下载和发布后的 latest 公网完整下载，SHA256 全部一致。发布后业务 API readiness 返回数据库 ready。

同一源码此前已完成 1,497 项 Flutter 测试、分析检查及仓库验证，详情见 `2026-09-09-avatar-cache-unification.md` 和 `2026-09-09-redmi-polish.md`。本次未变更产品代码。Redmi 保留已安装的同版本 Debug 包；其签名与正式版不同，本次未卸载用户应用或清除数据，也未将正式版实机覆盖安装描述为已验证。

## 更新配置与范围

通过受控 SSH 运维通道调用线上应用服务，先用 `AppUpdateSettingsBody` 校验，再用一次 `SettingService.set_many` 事务写入版本、构建号、最低支持构建号、文案及不可变 APK URL。发布 actor 为 `ops-codex-android-release`，trace 为 `android-release-0.3.67-2070-20260909`。读回一致，审计记录正好五条；重复校验没有重复写入。

客户端路由的应用内投影确认 `configured=true`、`latest_build=2070` 及正确下载 URL。该检查是受控运维进程内调用，未冒充已验证的登录客户端 HTTP 请求；公网匿名更新接口要求认证。

本次发布的是 Android 应用更新检查配置和 APK，未发送逐用户消息推送。现有 iOS 发布工作流使用 `LIUHETONG_IN_APP_UPDATE=false`；本次未运行 iOS 构建、TestFlight 或 IPA 发布。服务端更新字段为共享 APK 元数据，并非新增平台独立的 iOS 配置。

更新文案覆盖头像与朋友圈缓存、详情及图片/Emoji 评论、媒体复用、群聊通知样式、长按菜单边界、引用对齐和大表情排列。

## 证据与回退

本地原始证据位于被 Git 忽略的 `docs/verification/artifacts/2026-09-09/redmi-polish/`：

- `source-release-2070-final.log`、`rebuild-release-2070.log`。
- `package-release-2070/verification.json`、`identity.txt`、`signature.txt`。
- `release-2070-before-settings.json`、`release-2070-publish.log`、`release-2070-latest.log`、`release-2070-postflight.log`。
- `release-settings-2070.py` 为本次应用服务发布与保护性回退脚本。

服务器持久备份位于 `/opt/starchat/docs/verification/artifacts/2026-09-09/android-release-2070/`，包括原五项配置、旧 latest 目标、发布脚本与下载校验包。需要回退时，先确认未有后续版本发布，恢复脚本所需原配置备份后执行其 `rollback` 模式，再原子恢复旧 latest 目标并复核。该回退尚未执行，不删除新旧 APK，不涉及数据库迁移、业务镜像或钱包配置。
