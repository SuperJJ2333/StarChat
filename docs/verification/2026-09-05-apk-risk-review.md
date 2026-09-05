# Redmi K80 / HyperOS APK 告警复核

日期：2026-09-05。用户报告：畅聊 ChatFlow 安装提示“安装该应用存在高风险，包含病毒：a.gray.BulimiaTGen.f”。未取得手机上的 APK 哈希、HyperOS 完整版本、安全引擎版本或扫描报告。本次为静态核验，不是病毒扫描或动态安全认证；未修改产品代码、未发布构建、未上传样本或提交申诉。

## 实际检查的样本

- 从项目发布地址下载 `https://www.liuhetong888.com/downloads/ChatFlow-0.3.36-arm64.apk`。
- 包名 `com.liuhetong.mobile`，版本 `0.3.36`，versionCode `2039`，minSdk 24，targetSdk 36。
- SHA256：`d78e8c9ade0f024284fa2f972b8a01d3f48e929e5fb933f3d387ac64706407d3`，与现有 CI 发布记录一致；尚不能证明与用户手机样本相同。
- apksigner 验证通过，v2 签名有效，RSA 4096，证书主体 CN=Liuhetong；不是 Android Debug 证书。证书 SHA256：`b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6`。签名有效只能说明完整性和签名身份，不能证明无恶意代码。
- 同时检查本地 0.3.35 arm64 包，签名证书相同；0.3.36 比其新增 MANAGE_OWN_CALLS 和 FOREGROUND_SERVICE_PHONE_CALL 声明。

## 已证实的发现

1. `android/app/build.gradle.kts` 已启用 R8 和资源压缩；`scripts/build_mobile_public_domain.ps1` 已传入 `--obfuscate` 与 `--split-debug-info`。混淆并非缺失。脚本注释称可去除明文字符串、降低报毒概率，没有相应验证证据；Dart 混淆不能等同于字符串加密或杀毒修复。
2. 0.3.36 包含个推 PushService、GTIntentService、GService、GetuiActivity、PopupActivity 等组件，其中部分组件 exported=true，需要依据 SDK 文档核验保护与调用路径。不能仅由组件名或 exported 属性判断恶意。
3. Gradle 声明 gtsdk 3.3.15.0、gtc 3.3.3.0、gsido 1.4.14.0。APK 中 `libzxprotect.so` 的 SHA256 为 `AF596CD5F46A6382039EBD16C617A160C322A1B5162723A5463F8017B9CD9772`，与本地 Gradle 依赖 `sdk-prod-channel-getui-3.3.7.58976` 的 arm64 文件一致；gtsdk POM 引用了该依赖。该库可以归因，不能因为 protect 命名就认定为病毒或断言应用已整体加壳。
4. 实际清单包含锁屏显示、点亮屏幕、全屏来电、精确闹钟、电池优化豁免、前台服务和媒体权限。此次对实际清单的检查未命中 REQUEST_INSTALL_PACKAGES、READ_SMS、RECEIVE_SMS、QUERY_ALL_PACKAGES、SYSTEM_ALERT_WINDOW、无障碍绑定权限、通知监听绑定权限或 debuggable 声明。工作区源清单已有 SYSTEM_ALERT_WINDOW，说明当前源码与发布样本也存在差异，应以具体 APK 为准。
5. 更新代码 `launchAppDownload` 调用外部应用打开 URL；这个函数本身不是静默安装。没有证据证明这是 BulimiaTGen.f 的触发原因。
6. 当前 minimal flavor 同样继承 implementation 级个推依赖，并修改 applicationId 为 .audit；它不能作为仅移除推送 SDK 的单变量对照。旧 minimal APK 的时间、代码版本也与当前线上包不同。

## 旧报告的适用性

`docs/ANDROID_SECURITY_AUDIT.md` 基于 0.3.26 的“无 Push SDK”和仅有少量组件等内容不适用于本次样本。其将 Bulimia 名称解释成自动下载/诱导安装、将更新功能列为最可能误报源的推论，未有厂商规则说明或受控复测支持；不得直接用于证明当前包安全。旧报告保持原样以保留历史，本报告作为当前补充。

## 建议处理顺序

1. 固定手机报毒样本，记录哈希、完整系统版本、安全引擎与病毒库版本、告警截图及是否安装前即触发；先与本次样本核对。
2. 对同一代码基线、同一签名及尽可能一致的包身份制作内部诊断构建：先真正排除个推及其传递依赖（关闭初始化不足以排除静态命中），再分别测试非必需后台/锁屏行为及更新入口。每次只改变一项，在同一设备和可比的病毒库条件下检测。某个新哈希不再报毒也不足以单独证明根因，需重复和厂商确认。
3. 若定位到 SDK，联系其供应商核验必要模块、集成配置及合规版本，并回归消息与锁屏来电；若发现真实危险行为，应修复后重新扫描。权限和组件裁剪必须有功能回归，不应盲目删除通话所需能力。
4. 无恶意行为证据且厂商判定可疑时，向小米反馈；若设备确认使用腾讯引擎，通过腾讯官方申诉入口提交实际样本、哈希、签名、SDK/权限用途和复测记录。本次未代用户提交。
5. 不建议为消除告警加壳、反复改包名/换签名或关闭系统查杀。保留现有混淆可用于常规发布保护，但不把它作为报毒修复指标。

## 外部依据

- Flutter 官方混淆说明：https://docs.flutter.dev/deployment/obfuscate
- 个推官方集成说明：https://docs.getui.com/getui/mobile/android/androidstudio/
- 个推 SDK 合规指南：https://docs.getui.com/compliance/getui/
- 腾讯官方申诉入口：https://m.qq.com/complaint （本次访问跳转至登录页）
- Cromite 仓库同名告警的一手用户报告：https://github.com/uazo/cromite/discussions/943 。只能支持该名称也出现于其他项目并被报告与腾讯引擎相关，不能证明本项目是误报或判定此手机使用何种引擎。

## 原始证据

`docs/verification/artifacts/2026-09-05/apk-risk-review/` 保存公开下载样本、aapt 清单/权限/版本输出和 apksigner 验证输出。未执行产品测试套件，因为未修改产品代码；未进行动态运行、联网抓包或多引擎扫描。当前结论：完成静态初查，未确认告警根因，未证明告警已消除。
