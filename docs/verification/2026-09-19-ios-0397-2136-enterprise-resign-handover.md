# iOS 0.3.97 (2136) 企业重签候选交接

## 授权与状态

2026-09-19 用户授权同源 Android 发布并提供 iOS IPA 供用户企业签名。本记录仅负责 iOS CI、取回及验证；没有上传 TestFlight、修改 iOS 线上设置、manifest 或分发链接，也没有企业重签或真机安装验收。

冻结源码：`96637621fc2bf7f09259d62a1f4764eb1188f8ce`，版本 `0.3.97+2136`。main push 自动触发现有工作流，未重复 dispatch。查询最近六次签名工作流及其源码 pubspec：只有本次使用 2136，前五次均为 2134。

## 可交接文件

- [待用户企业重签 IPA](artifacts/2026-09-19/conversation-mobile-release/ios/ChatFlow-0.3.97-2136-enterprise-resign-candidate.ipa)，60,499,612 bytes。
- IPA SHA-256：`cdfaf35458917bbb488c82984e638eab877d142b879e606e8ec15c2169690a53`。
- Actions artifact `10583737840`，ZIP 60,120,658 bytes，SHA-256：`3e326ef878b2f4b17e5df99797d75627553b09165c239e0fdc2b0cb461a8d82e`；分块下载后尺寸及 digest 与 GitHub metadata 一致。
- [机器可读验包结果](artifacts/2026-09-19/conversation-mobile-release/ios/ChatFlow-0.3.97-2136-enterprise-resign-candidate.verification.json)。

这是 `ChatFlow_AppStore` 描述文件签名的候选，不能称为已完成企业分发的安装包。

## CI 与本地证据

| 门禁 | 证据及结果 |
| --- | --- |
| iOS 签名候选 | [run 35441268068](https://github.com/SuperJJ2333/StarChat/actions/runs/35441268068)，success；[完整日志](artifacts/2026-09-19/conversation-mobile-release/ios/ios-signed-ci.log) |
| Flutter / Android / 后端 CI | [run 35441268045](https://github.com/SuperJJ2333/StarChat/actions/runs/35441268045)，全部 success；Flutter analyze 无问题、3543 tests passed；[Flutter 日志](artifacts/2026-09-19/conversation-mobile-release/ios/flutter-ci.log) |
| 完整生产 iOS 原生编译 | compatibility run 内 job `105892342611` success；[日志](artifacts/2026-09-19/conversation-mobile-release/ios/production-native-compile.log)，Runner.app 93.8 MB |
| iPhone 15 iOS 18 模拟器 | [run 35441268083](https://github.com/SuperJJ2333/StarChat/actions/runs/35441268083)，实际 iOS 18.6：seed 20 tests passed、独立新进程 verify 3 tests passed；[证据](artifacts/2026-09-19/conversation-mobile-release/ios/ios18-test-evidence.json)，artifact `10584028143` 下载 digest 校验通过 |
| iPhone 15 iOS 26 模拟器 | 同 run 最终 success，实际 iOS 26.2：seed 20 tests passed、独立新进程 verify 3 tests passed；[证据](artifacts/2026-09-19/conversation-mobile-release/ios/ios26-test-evidence.json)，artifact `10584560230`（2,086,935 bytes）下载 digest 校验通过 |

CI 工具链：macos-15、Xcode 26.3、Flutter 3.44.9。原生通话 / Keychain Swift 测试 25 项、0 failures。CI 执行 `codesign --verify --deep --strict`，实际输出签名、production APNs、iPad 权限声明和 SQLCipher 加载顺序通过；输出的 IPA SHA 与下载文件逐字一致。Windows 本地不冒充执行 macOS codesign。

模拟器兼容测试是诊断配置：因 MLKit 不提供 arm64 simulator，该工作流暂时排除 `mobile_scanner 6.0.11`，不覆盖扫码及完整生产插件组合。完整生产 device compile 是独立门禁；二者通过仍不能替代企业重签后真机验证。

本地 Python 3.11.11 [验包脚本](artifacts/2026-09-19/conversation-mobile-release/ios/verify_candidate.py) exit 0：

- Bundle ID `com.liuhetong.liuhetongMobile`，版本 0.3.97 / 2136，MinimumOSVersion **16.0**，UIDeviceFamily `[1, 2]`。
- Runner arm64、`cryptid=0`；检查 Runner、App.framework、Flutter.framework、SQLCipher.framework 未发现 DRM 加密。
- Team `HY9Q7Q35S5`，APNs production，`get-task-allow=false`，后台 audio / voip / remote-notification，麦克风及相机权限声明存在。
- 内嵌 SQLCipher 存在，Runner 对 SQLCipher 的加载不被系统 SQLite 遮蔽。
- 包内统计 HTML 与冻结 SHA 的源码逐字哈希一致：`89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5`。
- 与本地 2134 App Store 候选（SHA `5bf564e0244f0b78d6bc153c8c809743b0d812fcbef397c8f87ae5582bafe743`）比较：两者签名 entitlements 均**未显式声明** `keychain-access-groups`，application-identifier 均为 `HY9Q7Q35S5.com.liuhetong.liuhetongMobile`。没有增造访问组；这不是企业重签后账号保留的真机证明。

验包脚本初次因错误额外要求非空 Keychain 组而失败；读取新旧实际 entitlements 确认两者均未声明后，改为比较声明状态、组集合与 AppID，复跑通过。没有修改 IPA 或产品源码来通过检查。

## 时间与下一步

全部时间为 2026-09-19 HKT：自动触发 19:51:52；签名 job 19:52:01–20:02:36（10分35秒）；完整原生编译 19:52:00–19:59:46（7分46秒）；Flutter CI job 19:51:55–20:01:13（9分18秒）；iOS 18 模拟器 job 19:51:59–20:12:24（20分25秒）；iOS 26 模拟器 job 19:51:59–20:17:00（25分01秒）。三个同 SHA 工作流最终全部 success。这些 CI 并行区间不可相加。取回及本地验包在 20:09 前完成；本地主动操作及下载精确分段时长未单独计时，不编造。

下一步：将上述候选交给用户企业重签。用户返回重签 IPA 后重新核验实际 SHA、Bundle / version、签名 entitlements、企业 profile / Team、Keychain 关系、资源和原生代码内容，再验证保留数据的覆盖安装、账号/历史保留、推送及音视频。未经这些步骤不能宣称企业安装或真机验收完成；当前没有改动 iOS 线上。
