# iOS 0.4.36+2205 待企业签名 IPA

用户授权打包最新iOS IPA并自行企业签名。本次已构建、下载和验包；未导入签名材料、上传Apple、合并main或改生产下载/更新弹窗。

- 源码：c628fe2e6706000cd721d6118c3e8ef8d372d7e2，分支codex/ios-history-ipa-2205；复用历史/弱网/语音修复3c37b529，产品差异仅成对版本。依赖pub锁SHA79437b4f…e885保持。
- 成品：[ChatFlow-0.4.36-build2205-unsigned.ipa](artifacts/2026-10-08/ios-ipa-history-fix/delivery/ChatFlow-0.4.36-build2205-unsigned.ipa)，44,599,097bytes，SHA256 `cbf78748f9d7855115cb05bce4f3339b307e23b631459fa4133ddfe112720a3b`。
- 身份：com.liuhetong.liuhetongMobile，iOS16.0，iPhone/iPad，arm64真机Release，完整543Payload文件、46device frameworks与29生产plugins。扫码器实际ObjC实现、权限方法表及五usage说明、VoIP/audio/remote-notification、SQLCipher加载顺序和6真实key/blob exports均通过；统计HTML源码/包内SHA一致。
- 签名交接：[Runner.entitlements](artifacts/2026-10-08/ios-ipa-history-fix/delivery/Runner.entitlements)、[build manifest](artifacts/2026-10-08/ios-ipa-history-fix/delivery/build-manifest.json)、[SHA256SUMS](artifacts/2026-10-08/ios-ipa-history-fix/delivery/SHA256SUMS.txt)。entitlements为源期待配置，不能当已签权益；回签后的Team/App ID/Keychain及保留数据覆盖安装须验证。

## 实际构建与原生验证

[GitHub run37750813785/attempt1](https://github.com/SuperJJ2333/StarChat/actions/runs/37750813785) exactc628fe2e，两job实际SUCCESS。device113223287016于16:45:53+08完成，simulator113223286743于16:56:12完成，总CI16:35:10–16:56:13（21分03秒）。固定Flutter3.44.9/Xcode26.3、macos15；完整device插件、官方pub.dev enforce-lockfile、CocoaPods、无签名发布编译97.9MB Runner；实际Ruby权限hook2PASS/0skip，permission binary gate通过。

独立fresh iPhone15/iOS26.2运行13迁移+4SQLCipher readonly/WAL+1Keychain=18PASS，三命令均attempt1、真实exit0、无VM stall/硬超时；首次构建在命令计时内，477.27/143.81/177.08秒。迁移1k/10k/100k/250k分别4/40/391/977页、maxPage256、计时280/472/4456/9102ms且timerTicks非零；retainedSearch100k为14592ms。只在该测试宿主排除无arm64 simulator slice的scanner，device真实实现保留；合成测试不代表真机帧/声学/APNs或企业覆盖升级验收。

IPA/device/native artifact11538342797/11538417173/11538374838的API digest、下载文件和ZIP CRC均真实一致。root本地验包、独立实际46framework Mach-O/所有SHA/生成Pod及registry、权限方法和全部归档byte inventory检查通过。最后规格审查接受（artifact-spec/final-review.md）；随后最终质量审查接受（artifact-quality/final-review.md，SHA256 ead24f859a42eef2575c9cf642b76314dd912746605156c8ceb965dd26577b49），无未解决P0/P1/P2；详情见[独立任务](../workflow/tasks/2026-10-08-ios-history-ipa.md)。主工作区交付副本与managed SHA一致，产品WIP未复制覆盖。

已识别的既有提示包括Flutter插件SPM未来迁移、Node20由runner运行Node24、第三方Pod nullability/deprecation/SDK路径/resource提示。photo_manager privacy编译提示未造成manifest缺失，实际IPA含photo_manager_privacy.bundle/PrivacyInfo.xcprivacy。没有隐藏native/assertion失败；原始日志和警告保留。

共享修复5632PASS/9既有诊断skip按不变输入复用；本次新增版本Python23PASS/Flutter33PASS、验包32PASS、移动Python386PASS/1Windows Ruby skip、wrapper格式/分析与workflow语法/有序实现双审通过。root .env仍缺，聚合verify未执行；未导入生产秘密。iOS原生18PASS属于本次真实结果。

恢复入口：[任务](../workflow/tasks/2026-10-08-ios-history-ipa.md)、[计划](../superpowers/plans/2026-10-08-ios-history-ipa.md)、[规格](../superpowers/specs/2026-10-08-ios-history-ipa.md)。时间首个可靠clock15:42:02，实际任务开始更早未知；CI墙钟21分03秒，准备/并行审查及下载验包另记任务，不相加各并行阶段。
