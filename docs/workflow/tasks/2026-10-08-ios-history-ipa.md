# iOS 最新历史修复 IPA 待企业签名交付

## 恢复入口

- 用户授权：2026-10-08“打包iOS的ipa安装包，我会自行进行企业签名”。仅构建/验包/交接；不发布官网、更新弹窗、TestFlight或main。
- 源/工作树：C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat，复用本chat附加干净checkout；父6ae1357a、修复3c37b529，新branch codex/ios-history-ipa-2205。primary原产品WIP保持。
- 状态：IPA打包与签名交接完成；device和simulator CI均SUCCESS，原生18PASS，成品SPEC→QUALITY均接受。目标0.4.36+2205，Bundle ID com.liuhetong.liuhetongMobile；实际正式iOS先前2194、Android2204，不覆盖旧产物。
- [规格](../../superpowers/specs/2026-10-08-ios-history-ipa.md)、[计划](../../superpowers/plans/2026-10-08-ios-history-ipa.md)。本轮首次可靠clock15:42:02+08，实际启动更早未知。
- 文件所有权：root成对版本、台账/计划/规格/索引/下载交付；pipeline代理仅new workflow/prepare script/对应Python测试；native预检代理另独占新增integration_test/ios_timeline_storage_migration_native_test.dart及其证据子目录。禁止并发U Flutter/生成操作。
- 下一步：向用户交付下述实际IPA；用户企业重签后，验证最终签名权益及保留数据覆盖升级。打包范围无剩余工作。

## 验收台账

| ID | 要求 | 状态/证据 | 未完成边界 |
| --- | --- | --- | --- |
| SOURCE | latest shared history/weaknet/voice修复、版本一致 | 源3c37b529已5632PASS9诊断skip、Android编译、双审；本次bump3PASS、版本相关Python23PASS、Flutter33PASS；1447输入冻结（新增原生测试入口1），旧输入仅两版本文件区别 | exactc628fe2e device及native均SUCCESS |
| NATIVE | 完整device plugins、SQLCipher新worker/Keychain/WAL/权限 | device actualRuby2PASS0skip、Runner权限方法表、五usage声明、6exports及SQLCipher加载顺序PASS | simulator迁移13、SQLCipher/WAL4、Keychain1，共18PASS；最终签名及真机验证后续进行 |
| IPA | arm64 release、Payload完整、CFBundle/资产/lock/6exports/源码身份 | deviceSUCCESS、IPA44599097bytes/SHAcbf78748…20a3b，root及独立device检查PASS，完整543files/46frameworks/29plugins | 原生18PASS，最终成品SPEC→QUALITY接受；待用户企业重签 |
| HANDOFF | 实际IPA+entitlements/manifest、SHA/大小 | IPA、entitlements、manifest、SHA及说明已保存至primary delivery，SHA一致；用户自行企业签名 | 本包不证明最终签名/保留数据升级或真机帧 |
| PUBLICATION | 不自动改发布/弹窗/Android | 未执行生产写入 | 发布不在本次授权范围 |

## 版本与证据

- 证据：docs/verification/artifacts/2026-10-08/ios-ipa-history-fix；Token仅经既有GCM内存使用，不落盘/输出。native-preflight初始35项基于2204，升版后需重捕获，不误标为2205输入。
- 本机Windows无Xcode；GitHub API权限及Actionsenabled已真实核实，runner工具按既有macos15/Xcode26.3/Flutter3.44.9固定。unsigned full-device路径不使用Apple signing Secrets。
- root/source-freeze.json保存1446输入字节SHA；与前共享全量1424输入比较仅pubspec和app_config版本变化。pubspec.lock SHA79437b4f…e885不变；共享5632PASS/9既有skip及分析0按影响复用，当前iOS运行不能由旧CI替代。
- 新原生入口后source-freeze重捕获1447输入。root/git-byte-preflight.json验证lock、statisticsHTML与worker实际Git blob和本机字节一致；macOS不是靠换行差异绕过SHA门禁。
- root/version-bump.log、version-focused-python.log实际exit0，Python3.11.11；root/version-focused-flutter.json/log实际exit0、33PASS，Flutter3.44.9/Dart3.12.2、单一U路径。聚合scripts/verify.ps1前检依赖root .env仍缺失，未执行；不导入生产秘密。
- 构建前审阅真实Flutter3.44.9 commands/test.dart识别规则，发现外部RUNNER_TEMP Flutter-test目标会被当host widget。改用新增永久integration_test入口运行同迁移suite，并显式iOS断言；该准备阶段纠正尚未启动CI，不计native PASS。
- wrapper格式0变化、分析0issues（root/ios-wrapper-host-gates.json）；新增helper实际RED30→32PASS，移动全量386PASS/1既有Windows Ruby skip、Python3.12.10/pytest8.4.2，详见pipeline/validation.json。修正前directory-symlink fixture导致32专项/全量各一项失败均保留，不用旧采集输入的结果称最终PASS。
- workflow RED1→GREEN1、11bash/8embeddedPython语法PASS（workflow/REPORT.md）。SPEC最终接受，无未解决P0/P1/P2，六输入无漂移（spec-review/final-review.md，SHA111a2846…ec09）；权限声明缺口已通过device source→built五key门禁补齐。QUALITY待结果；未启动CI。
- root/live-version-preflight.json两端匿名latest均401，未取得生产版本新读回、未取生产token。此轮版本选择由本地/最近CI与候选branch占用检查支持，2194/2204仍明确为前任务快照。
- 最终QUALITY接受、六输入无漂移，无未解决P0/P1/P2（quality-review/final-review.md，SHAdcfcd7e0…8166）；这是构建前实现审查，CI和成品仍待执行。只推新候选branch，已检查其他现有production/sign/upload workflow不会因该branch触发。
- 真实源码提交c628fe2e6706000cd721d6118c3e8ef8d372d7e2，16:35:10+08 GitHub创建run37750813785/attempt1/eventpush，head/path读回一致（root/candidate-commit.json、candidate-push.log、ci-identity.json）。job device113223287016、simulator113223286743均in_progress；[CI](https://github.com/SuperJJ2333/StarChat/actions/runs/37750813785)。只推codex/ios-history-ipa-2205；main与发布环境未写。
- device job16:45:53+08真实SUCCESS。build97.9MB完整Runner，pod103.0s/Xcode352.8s；IPAartifact11538342797（outerZIP digest6b073127…9960）、deviceevidence11538417173（820dac5f…b8be）已下载并API digest/CRC一致。delivery/ChatFlow-0.4.36-build2205-unsigned.ipa实际44599097bytes/SHAcbf78748f9d7855115cb05bce4f3339b307e23b631459fa4133ddfe112720a3b；对应ci-device与root/device-job-final.log保存。
- root/verify_download.py对真实IPA/sourcecommit/run37750813785/attempt1验包exit0；独立artifact-spec/device-inspection.json +archive-bindings.json核对543Payloadfiles/46实际arm64 device框架/29生产plugins、全部SHA、权限方法和scanner真实ObjC实现均通过。旧native或同源host证明未用于替代simulator结果；final_acceptance仍false。
- 已识别的构建提示：未签名设备安装提示符合本次交付渠道；Flutter现有plugins的SPM未来迁移提示由当前明确CocoaPods路径执行，未改依赖；ActionsNode20deprecated由runner运行Node24，无native/build失败。不是零warnings声明。

## 阶段计时

| 阶段 | +08起止 | 类型 | 结果/下一步 |
| --- | --- | --- | --- |
| 入口/构建路径 | 本轮首次可靠clock15:42:02，实际开始更早未知 | read-only/并行原生预检 | GCM/API可用；旧native/signedmain成功；无2205占用迹象；新IOS运行不能由旧CI替代 |
| 版本相关Flutter | 15:56:31.724–15:56:43.380+08 | tooling 11.656s | 33PASS/exit0；输入记录与日志SHA具名保存 |
| pipeline/原生入口准备 | 至16:26:50+08可靠clock；各代理主动起止未精确记录 | 并行实现/返工/审查 | helper32PASS/全移动386PASS，host wrapper0issues；完整SPEC接受；下一步QUALITY→候选push/CI |
| CI构建/原生执行 | 16:35:10+08创建、device16:35:17/sim16:35:18启动；终点待回执 | 外部tooling，并行 | run37750813785/attempt1、exactc628fe2e；Windows门禁不能替代该执行结果 |

## 交接与回退

未更改账号/数据/E2EE/财务/签名身份。保持源entitlements的production APNs等期待配置，未签包不宣称实际已签权益；企业Team/App ID/Keychain兼容及不卸载覆盖升级须由后续回签最终SHA验证。仅新增候选branch，不合main/删除其他branch；CI失败保留首有效错误、run/attempt/source身份后有依据重试。

## 最终交付记录（替代以上阶段性待执行状态）

- CI run37750813785/attempt1，两job真实SUCCESS，16:35:10–16:56:13+08，墙钟21分03秒。原生13迁移+4SQLCipher/WAL+1Keychain=18PASS，全部attempt1/exit0。
- 成品SPEC接受：artifact-spec/final-review.md，SHA256 b78bfa0babc290505e44cdacd19d7304c8034ce41efcf5adc1c90cb6c80a1078；随后QUALITY接受：artifact-quality/final-review.md，SHA256 ead24f859a42eef2575c9cf642b76314dd912746605156c8ceb965dd26577b49。无未解决P0/P1/P2。
- 实际交付路径：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-08/ios-ipa-history-fix/delivery/ChatFlow-0.4.36-build2205-unsigned.ipa。44,599,097字节；SHA256 cbf78748f9d7855115cb05bce4f3339b307e23b631459fa4133ddfe112720a3b。
- Runner未签名；部分framework保留上游签名资源，企业交接须重签整个App及Frameworks。Bundle ID保持com.liuhetong.liuhetongMobile，源entitlements不是实际已签权益。
- primary副本、签名交接及说明已完成。打包交付验收完成；最终企业签名、真实设备保留数据升级/APNs/VoIP/audio/帧耗时属于后续签名和设备验收，不宣称已验证。