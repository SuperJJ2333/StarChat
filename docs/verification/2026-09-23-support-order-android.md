# 2026-09-23 客服异步充值提现 Android Debug

最终交付：Mi6已保留数据覆盖安装0.4.2+2161；2160仅作历史工件，已被替代。2161修正备用版本常量遗漏，版本门禁16/16、Dart专项31/31、范围分析和完整重建验包通过。详见末节。

## 恢复入口与授权

用户明确授权部署生产并把新 APK 安装到 Mi6。Android 子任务独占 apps/mobile_flutter/pubspec.yaml 版本、Android 生成文件和本报告；不改其他产品源码，不提交 Git。服务端由主代理处理。来源 main 398ffbd5，构建前工作树干净；仅递增版本至 0.4.2+2160。

计划：../superpowers/plans/2026-09-23-support-order-workflow.md；行为与测试依据：2026-09-23-support-order-workflow.md。复用已通过的 Flutter3875、钱包126、analyze0 issue、verify exit0，不重复全量测试。本轮没有新增业务行为，完成版本、依赖与构建影响检查。

## 构建证据

工件：artifacts/2026-09-23/support-order-release/android/。

- Windows、PowerShell7 UTF8、Flutter3.44.9 / Dart3.12.2、Java17.0.20、Apktool2.12.1、Android build-tools36.0.0。
- 包名 com.liuhetong.mobile，Debug，单 ARM64，0.4.2+2160；三个 dart-define 均指向 https://liuhetong888.com（Matrix、Business API、Getui）。
- 正常 pub get 恢复生成流程；镜像仅替换锁文件URL，逐项核对版本及内容hash不变，恢复原锁文件。pubspec及锁SHA见 build-inputs.json、dependency-parity.txt。
- 源码构建 → 完整Apktool重建 → zipalign -P16 -f4 → 固定DPAPI签名 → 独立重解包验证，全部exit0。构建session1219、验包session93623均结束。
- 固定证书SHA256：75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。apksigner、签名后zipalign通过。
- 27317个类与339项原生库/资产全部一致；清单语义一致；DEX及resources.arsc确实重建。详见verification.json、rebuild-verification.log、identity.log。
- Debug含kernel，不能使用要求AOT libapp.so且禁止kernel的release专用ZIP脚本。已用aapt/资产/ABI/签名/独立重建门禁验证Debug。
- 构建保留既有Kotlin插件迁移预警：当前Flutter支持现有KGP，未来Flutter升级需插件迁移；本次未升级工具链且构建成功。没有把该提示隐藏为无警告。

最终APK：artifacts/2026-09-23/support-order-release/android/final.apk；145396011字节；SHA256 `8a5c6ff0af7ff639166525fa1dfe490e1940dfcaffab36c21c0adbcfc4a124ec`。

## 真机状态

Mi6 cbd0156b在线，安装前0.4.1+2159；从设备读取的APK证书匹配固定身份。主代理确认生产 schema0087/API/worker/静态及公网检查就绪后，14:50:40+08完成 adb install -r 覆盖安装，exit0/Success；没有卸载、清数据或降级。设备读回0.4.2+2160 Debug，firstInstallTime仍为2026-09-20 09:35:24。MainActivity启动Status: ok；14:51:14+08应用进程29513存在。设备APK读回完整SHA与最终工件一致，apksigner再次确认固定证书匹配。证据见installed-after.txt、install.log、launch.log、installed-verification.json、device-readback.json。未发短信、未操作真实资金/钱包。尚未声称新业务真机验收通过。

## 阶段计时与下一步

构建开始2026-09-23T14:42:37+08:00；源码Gradle46.7秒；14:44:31前源码重建签名完成；约14:46完成独立验包。精确阶段计时以日志和build-inputs为准，未记录的人工准备时间未知。约14:46至14:50等待生产就绪；安装session99791 exit0，14:51:14+08完成设备签名/哈希/进程读回。构建与真机交付完成，所有本任务工具session已结束。下一步由用户验收客服充值/提现交互和到账通知；本次未改官网Android正式分发设置，未做iOS构建。


## 2161 版本一致性返工（最终交付已完成）

主代理最终版本门禁发现本子任务遗漏：2160仅更新pubspec，AppConfig备用版本仍为0.4.1/2159。运行时正常读取安装包版本，但这不能替代构建常量一致性门禁。保留2160全部工件，不把首次交付视作最终验收通过。

新工件目录：artifacts/2026-09-23/support-order-release/android-2161/。先重现pytest版本门禁1failed/15passed（version-red.log，exit1），仅修正pubspec至0.4.2+2161及app_config.dart两行常量0.4.2/2161；相同门禁16passed（version-green.log，exit0），未修改测试。Flutter AppConfig/更新/iOS路由/关于页专项31passed，dart analyze lib/core/app_config.dart无问题（session79833 exit0）。业务测试复用原结果。

2161在版本三值一致后开始源码构建。Gradle27.5秒；完整重建签名验包均exit0（构建session35815、独立验包79031）。27317个类、339项原生库/资产全部一致，清单语义一致，DEX和资源已重建；aapt版本/Debug/ARM64、固定证书、zipalign门禁通过。构建前可用磁盘5.42GB，无需清理旧工件；保留2160最终APK及日志。返工开始时间见2161/build-inputs.json及red日志，本阶段为版本门禁遗漏导致的额外执行时间。

最终2161 APK：`artifacts/2026-09-23/support-order-release/android-2161/final.apk`，145412395字节，SHA256 `d4526bb03b5c3e0d490a7214e53132a8b54774db0968e6e25ac8958763b8d185`。

2026-09-23T14:59:10+08安装完成（session60695 exit0，adb install -r，Success），读回0.4.2+2161 Debug；firstInstallTime维持2026-09-20，未卸载或清数据。MainActivity启动Status: ok。14:59:37+08设备APK完整SHA、固定签名一致，进程9939存在。安装及读回证据位于2161目录；所有工具session已结束。下一步用户验收真实客服充值/提现及通知效果，未自动执行真实短信或资金操作。
