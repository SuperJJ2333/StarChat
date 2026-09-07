# Mi 6 会话修复 debug 测试包

2026-09-06，用户明确要求推送debug并使用debug签名；沿用设备已安装签名并保留数据的授权仍有效。

- 代码：89367fa，分支codex/chat-room-flow-fixes。源代码已通过1245项Flutter测试与analyze。
- standard / ARM64 / debug，versionName 0.3.48，versionCode 2050（原安装0.3.45/2048）。通过构建参数递增测试包版本，不修改正式版本序列。
- Business API、Matrix、Getui三个dart-define均为https://liuhetong888.com。
- 固定流程：Flutter源码构建 → Apktool2.12.1完整解包重建 → build-tools36.0.0 zipalign -P16 → 原有Android Debug签名 → 重新解包代码/清单/原生资产对照。
- 签名SHA256：34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1。设备旧APK、本机debug密钥、最终APK核对一致；未修改正式签名规范。
- 最终文件：docs/verification/artifacts/2026-09-06/room-flow-debug/ChatFlow-0.3.48-arm64-debug-rebuilt.apk。
- APK SHA256：caaaca53cb4624513ba5d98d730dd724495f5a973ba6179f564fd226713ed4f5；大小140822593字节。
- 24912个类、332项原生库/Flutter资产一致；清单语义一致；签名和对齐验证通过；仅arm64-v8a，debug kernel存在，DEBUGGABLE为true。
- adb -s cbd0156b install -r 返回Success。无卸载、无清数据、无-d降级参数。设备回读APK SHA256与本地一致，版本确认2050/0.3.48。
- MainActivity已启动，等待后进程仍运行；当前进程crash buffer中fatal markers为0。未向他人发送测试消息；真实聊天/相册/群管理性能交由用户验收。
- 未替换线上正式APK。构建有第三方Kotlin插件迁移和Java弃用提示，不影响本次构建成功。

原始构建、重建、签名、逐项比对结果保留在上述artifact目录；APK、解包文件和密钥不提交Git。
