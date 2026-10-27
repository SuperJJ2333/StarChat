# 雷电冷启动发送 Debug 交付验收

用户要求将 Debug 安装到雷电自行测试。本轮仅构建与本地安装，计划和授权见[任务记录](../workflow/tasks/2026-10-27-cold-send-debug.md)。

## 交付身份

| 项目 | 实际值 |
| --- | --- |
| 版本 | 0.4.66+2235；由设备上的 Debug 2233 递增覆盖升级 |
| 包名 / 标签 / ABI | com.liuhetong.mobile.debug / 畅聊 Debug / x86_64 |
| 源码 | c6bdc6178b92ce8bf3ea54ba6dbeb0cc897b844b；运行修复 7b6a894b |
| 入口 | standard flavor、Debug、lib/main.dart，无 integration_test 入口 |
| APK | D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-27/cold-send-debug/debug-main-c6bdc617/final.apk |
| APK SHA256 | 3ac0f1b23a5d4cb902eb12484bbb9fd9957cb27262c81c852e847b4db67f58bf |
| APK 大小 | 126163290 字节 |
| 证书 SHA256 | 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff |
| 安装设备 | emulator-5556；原包0.4.64+2233，现0.4.66+2235 |

这是最新修复源码的本地 Debug；与官网同版本 ARM64 正式包的包名、源码、哈希分别记录。没有修改官网、更新提醒或 iOS 发布，也没有推送 Git。

## 构建与验证

证据目录为上述 cold-send-debug/。Flutter 3.44.9 / Dart 3.12.2、Microsoft JDK17.0.20、Python3.12.10、Apktool2.12.1、Android build-tools36.0.0；工具、环境、锁文件身份分别保存在 environment.json、flutter-version.json、tools-inputs.json 和构建 receipt.json。构建参数保存在 build-debug.ps1；三项业务/Matrix/个推 URL 均为既有 HTTPS 值。

先正常 `flutter pub get --offline --enforce-lockfile`，再冻结并构建 standard Debug / android-x64，明确 chatflowParallelDebug=true。不是以测试阶段残留生成配置直接构建。依赖锁 SHA256 a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d。

- `test-evidence-reuse.json`：1721 个上轮完整验证输入 SHA 一致，无移动源码改动；复用[冷启动发送源码报告](2026-10-27-cold-room-send-identity.md)中的结果与限制。
- `debug-main-c6bdc617/steps.tsv`：17 步 exit0，源码构建→完整解包/重建→zipalign16KiB→固定签名→重新解包/验收。2158 个构建输入前后一致，manifest SHA1825e285046c4dfaeee95221f901e3ae4d6ac68c69e4740ec23a2d31ae106cd3。
- 重建保留27386类、177848方法、27个DEX、475个资源条目；清单语义相同，274原生/Flutter资产条目逐字节一致。DEX二进制变化为重建结果，smali仅按既定严格默认值规则归一化，方法内容一致。
- v2/v3签名、固定单一证书、签名后zipalign、aapt包名/版本/debuggable/x86_64检查通过。13个原生库均为x86_64 ELF64，Debug kernel存在，无release AOT。
- `kernel-change.json`：新kernel SHA f888234deb79e19bfa821c200e786de861d7d4002ace52713f63c742937346be，115181424字节，含新增outbox v3字段；与原设备kernel不同。即使最终APK总大小与旧包相同，也已排除旧程序误用。
- `preinstall-review.json`：根代理先规格、后质量/安全复核工件及保留数据安装脚本；未宣称新增独立源码复审。

构建17:15:00–17:20:36+08:00，336.47秒。正常编译保留插件未来Kotlin迁移、旧API及unchecked提示；不将这些警告隐藏为无警告构建，本次未扩展至依赖升级。

## 安装与自测

`install-debug.ps1` 在操作前重新检查在线设备、原版本、UID、首次安装时间、旧APK哈希与已验证证书，然后仅执行 `adb -s emulator-5556 install -r`。安装成功，未卸载、清数据或降级。设备上APK SHA与最终交付一致，UID10090和firstInstallTime2026-09-26 04:06:20保持。

17:22:13–17:22:33+08:00完成安装和真实MAIN/LAUNCHER冷启动，am start返回Status: ok；进程存活，MainActivity在前台。证据为install.log、device-before.txt、device-after.txt、cold-launch.log、device-install-receipt.json。未读取或保存真实聊天内容，也未代用户发送消息。

待用户自行验证：完全退出“畅聊 Debug”后重新进入多人群，历史尚未完成时输入发送；检查落盘后本人气泡始终在右侧、恢复网络后同事务发送，以及上滑历史、@和引用、后台返回是否正常。启动与安装通过不等于这些真实聊天场景已验收。

首次运行outbox将沿已验证升级路径进入v3；不要安装旧v2二进制或清库回退。上轮全量一次Windows清理失败及未变输入补跑、缺.env的总门禁、Ruby/iOS和真机缺口仍见源码报告。本轮不是发布验收，尚无iOS或物理设备结论。
