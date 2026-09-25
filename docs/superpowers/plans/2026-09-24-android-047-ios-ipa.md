# v0.4.7 Android 更新与 iOS IPA 交付计划

状态：用户已授权。2026-09-24 用户明确要求 Android 新版本更新弹窗，并先取得 iOS IPA 自行加企业签；版本显示名选定 v0.4.7，构建号定为 2172。

## 范围和边界

- 源码：本任务沿用 `codex/online-room-refresh` 已实现并已复核的移动端功能；统一改为 `0.4.7+2172`，保留生产 API 当前已上线的相关功能。
- Android：只构建 arm64 standard Release，按固定 Apktool 2.12.1 常规重建、16K 对齐和既有证书签名；验证后上传不可变 APK，发布 Android 版本、构建号、URL 和准确更新说明，使现有 0.4.6 正式客户端收到更新弹窗。保持最低支持构建号 3。
- iOS：同一源码和版本生成带生产推送能力、可供企业重签的 IPA，交付文件、SHA256 和包身份。用户企业签回传前，不修改 iOS 下载入口、版本设置或更新弹窗。
- MI 6 当前内部 Debug 为 0.4.10/2171；其版本名高于 v0.4.7，不能用该 Debug 的更新弹窗行为代表 0.4.6 正式客户端。可保留数据安装 2172 以验证启动/签名兼容。

## 步骤与门禁

1. 记录线上 Android/iOS 设置、源工作树及目标版本；同步版本常量，复验版本契约及移动端最终候选相关门禁。
2. 冻结源码并提交到 `codex/online-room-refresh`，触发 iOS macOS CI；检查 CI 签名、bundle ID、版本、推送、SQLCipher、IPA SHA 和产物。
3. 同源构建 Android Release 中间包、常规重建、对齐和固定签名；比对 ABI、DEX、资源、清单、签名、版本及 SHA。经规格符合性、质量安全复核后才上传。
4. 在生产私有发布目录保存 0700 前态与回退证据，顺序上传不可变 APK 并核对 SHA，原子切换 latest-arm64 链接，进行 HEAD/页面/平台检查，再通过现有有审计设置服务发布 Android 弹窗元数据及本版更新说明。
5. 回读审计、Android 页面/接口与 iOS 原值，确认生产健康。记录 Android 公网链接和 iOS IPA 交付链接；iOS 标注待企业重签。

## 验收

- Android 正式 APK：`0.4.7/2172`、仅 arm64、固定证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；不可变 URL 可下载，0.4.6 客户端更新投影指向该 URL，iOS 原设置不变。
- iOS IPA：同一已冻结源码 `0.4.7/2172`、`com.liuhetong.liuhetongMobile`、生产 APNs、iPhone/iPad 支持、SQLCipher 校验通过；只交付候选，不发布 iOS 弹窗。
- 任一上传/设置写入失败时先读现态，按持久备份和漂移检查恢复；不盲目覆盖更新的版本。
