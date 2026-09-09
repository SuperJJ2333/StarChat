# MI 6 生产入口 debug 测试包

2026-09-06，用户要求debug构建且必须使用debug签名。该明确要求覆盖固定发行证书规则；仍按android-apk-rebuild.md执行源码构建、Apktool 2.12.1重建、build-tools 36.0.0对齐和重解包验证。

- 版本：0.3.49-debug / 2051，通过构建参数递增，不改变仓库正式版本。
- 包名：com.liuhetong.mobile；standard flavor；ARM64；application-debuggable，包含debug kernel。
- Business API、Matrix、Getui编译参数均为 https://liuhetong888.com；完整应用入口，没有使用.audit沙箱入口。
- 签名：现有Android Debug密钥；证书SHA256为34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1，与手机安装前包实测一致。未生成或分发私钥。
- 最终APK SHA256：068804a64a11cc903d96cc366f17de904555338762bdf7a697559641b06bda5b。
- 24,912个类重建前后smali一致，332项原生库/资产逐项SHA256一致，清单语义一致；apksigner与签名后16K对齐验证通过。
- MI 6 cbd0156b：adb install -r返回Success；未卸载、未清除数据。安装后versionCode2051、versionName0.3.49-debug及DEBUGGABLE标记核对通过，已启动MainActivity。
- 本轮只验证安装与启动；业务操作留给用户测试。生产真实充值/兑换/提现保持关闭。
- 构建保留现有Flutter插件Built-in Kotlin迁移提示；没有忽略构建失败。

最终APK：[final.apk](artifacts/2026-09-06/mi6-production-debug/package/final.apk)。签名、重建、安装日志位于同一任务工件目录。