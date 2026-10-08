# iOS 最新历史修复 IPA 待企业签名交付

## 恢复入口

- 用户授权：2026-10-08“打包iOS的ipa安装包，我会自行进行企业签名”。仅构建/验包/交接；不发布官网、更新弹窗、TestFlight或main。
- 源/工作树：C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat，复用本chat附加干净checkout；父6ae1357a、修复3c37b529，新branch codex/ios-history-ipa-2205。primary原产品WIP保持。
- 状态：版本/源码及unsigned pipeline冻结、SPEC→QUALITY接受，准备候选push/CI。目标0.4.36+2205，Bundle ID com.liuhetong.liuhetongMobile；实际正式iOS先前2194、Android2204，不覆盖旧产物。
- [规格](../../superpowers/specs/2026-10-08-ios-history-ipa.md)、[计划](../../superpowers/plans/2026-10-08-ios-history-ipa.md)。本轮首次可靠clock15:42:02+08，实际启动更早未知。
- 文件所有权：root成对版本、台账/计划/规格/索引/下载交付；pipeline代理仅new workflow/prepare script/对应Python测试；native预检代理另独占新增integration_test/ios_timeline_storage_migration_native_test.dart及其证据子目录。禁止并发U Flutter/生成操作。
- 下一步：CI helper/test RED→GREEN→有序审查→只推候选branch→完整macOS device编译/独立simulator新worker门禁→下载验包交付。

## 验收台账

| ID | 要求 | 状态/证据 | 未完成边界 |
| --- | --- | --- | --- |
| SOURCE | latest shared history/weaknet/voice修复、版本一致 | 源3c37b529已5632PASS9诊断skip、Android编译、双审；本次bump3PASS、版本相关Python23PASS、Flutter33PASS；1447输入冻结（新增原生测试入口1），旧输入仅两版本文件区别 | iOS本轮尚未构建 |
| NATIVE | 完整device plugins、SQLCipher新worker/Keychain/WAL/权限 | GitHub macOS CI可访问；原先main be207f0f原生成功是旧源，不能复用为当前native PASS | 新源iOS运行待执行 |
| IPA | arm64 release、Payload完整、CFBundle/资产/lock/6exports/源码身份 | unsigned方案冻结；不需企业签名材料 | 构建/产物验包待执行 |
| HANDOFF | 实际IPA+entitlements/manifest、SHA/大小 | 用户自行企业签名 | 本包不证明最终签名/保留数据升级或真机帧 |
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

## 阶段计时

| 阶段 | +08起止 | 类型 | 结果/下一步 |
| --- | --- | --- | --- |
| 入口/构建路径 | 本轮首次可靠clock15:42:02，实际开始更早未知 | read-only/并行原生预检 | GCM/API可用；旧native/signedmain成功；无2205占用迹象；新IOS运行不能由旧CI替代 |
| 版本相关Flutter | 15:56:31.724–15:56:43.380+08 | tooling 11.656s | 33PASS/exit0；输入记录与日志SHA具名保存 |
| pipeline/原生入口准备 | 至16:26:50+08可靠clock；各代理主动起止未精确记录 | 并行实现/返工/审查 | helper32PASS/全移动386PASS，host wrapper0issues；完整SPEC接受；下一步QUALITY→候选push/CI |

## 交接与回退

未更改账号/数据/E2EE/财务/签名身份。保持源entitlements的production APNs等期待配置，未签包不宣称实际已签权益；企业Team/App ID/Keychain兼容及不卸载覆盖升级须由后续回签最终SHA验证。仅新增候选branch，不合main/删除其他branch；CI失败保留首有效错误、run/attempt/source身份后有依据重试。
