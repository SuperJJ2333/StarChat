# Android 0.4.38+2207 修复候选（未发布）

用户授权：排查并解决2205空消息列表/无法入房，并多次要求继续。关联[原调查与修复任务](2026-10-08-android2205-empty-room-investigation.md)及其[批准计划](../../superpowers/plans/2026-10-08-android2205-empty-room-investigation.md)。本阶段交付保留数据覆盖安装候选，不更改稳定2206官网和更新弹窗。

所有权：两版本字段、独立候选证据/打包脚本/本任务记录。工作树`C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat`；源修复c06caa24，回升兼容d4e438eb，版本c1883df71a7f3fa834ef375e904335de947ba504。源版本修改仅pubspec与AppConfig三声明，行为输入沿用最终5644PASS/9skip、边界364PASS/23skip、analyze无问题证据；版本契约3PASS与运行时版本Flutter8PASS另跑。

## 验收台账

| ID | 要求 | 结果 | 缺口 |
| --- | --- | --- | --- |
| SYNC | 收到响应后不预迁移无消息房间/将被limited替换的旧main | RED/GREEN，保留SENDING/RECOVERY；真实SDK恢复账号测试通过 | 用户手机单次未取得await栈，不称唯一根因 |
| ROLLFORWARD | 2206旧格式新增消息再次升级可见，删除标记与正文/密钥保留 | SQLCipher ready/copying/事务中断重试4PASS，65专项PASS | Windows数据库证据不替代Android运行 |
| PACKAGE | standard ARM64、完整icon字体、固定签名和常规重建 | 28构建/签名/对齐/代码资源门禁全exit0 | 不等于已安装 |
| FRESH | 最终移动输入/锁文件/生成依赖没有漂移 | 1904输入freeze，构建后/验包后/最终复查通过 | 正常pub get后只修正已知dev插件注册块，其他注册字节保留 |
| DEVICE | 不卸载覆盖升级，首次启动/同步、列表和入房恢复 | 未执行 | 无adb设备/AVD；用户先前无法USB连接，可自行覆盖安装候选 |
| RELEASE | 官网与全量更新弹窗 | 未执行 | 稳定Android2206/iOS2205保持，待DEVICE通过再发布 |

## 版本与证据

- Android0.4.38+2207，包名`com.liuhetong.mobile`，standard/ARM64 release，无Dart/R8混淆，完整icon字体。
- 候选最终APK83110942字节，SHA256 `ad8cc9d8826130449e21eb094b42728349bcf0590f021b71ac82e8c03fe0e324`；固定证书`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。
- 用户交付文件：`D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-09/android2207-fix-candidate/delivery/ChatFlow-0.4.38-build2207-arm64-candidate.apk`，复制后hash一致。
- [构建记录](../../verification/artifacts/2026-10-09/android2207-fix-candidate/android-arm64/run-20261009-012100/artifact.json)、[28门禁](../../verification/artifacts/2026-10-09/android2207-fix-candidate/android-arm64/run-20261009-012100/steps.tsv)、[重建语义](../../verification/artifacts/2026-10-09/android2207-fix-candidate/android-arm64/run-20261009-012100/rebuild-verification.json)、[冻结输入](../../verification/artifacts/2026-10-09/android2207-fix-candidate/mobile-inputs.json)。
- 25382类的smali语义保持、338原生库/资产字节一致、474资源保留，清单语义一致；6DEX重新编译。
- 三公网define保持HTTPS `https://liuhetong888.com`，保留性能诊断。Apktool2.12.1/build-tools36.0.0/Flutter3.44.9/Dart3.12.2/Java17.0.20；锁SHA `12ae67427fe7b17a65aa929773940cfef1ce97be4fe5240a925a373c771f191e`。
- freeze SHA `d8027af78e273ea48e1581a11b3d8dfe50d44e80fdbeac2f83af8fb33f677817`，1904输入；相对前次用户已验签打包driver只有版本替换，没有新签名/清单操作。

## 阶段计时与恢复

- 01:17:53–01:17:56+08只读生产版本检查exit0，服务器17:17:55UTC Android2206/iOS2205；没有生产写入。
- 版本契约3PASS/0.11s，运行时版本Flutter8PASS；源构建Gradle87.7s，整个包流程结束01:28:16+08。总开始时刻以命令/步骤文件记录为准，不把RunId当精确墙钟。
- 第一条准备命令工作目录误选mobile，重定向父目录不存在，执行版本修改前即失败；改在工作树根执行成功，未产生半改版本。
- 独立SPEC后QUALITY成品审查结果将追加。当前候选已完成包门禁，未上传/推送/合并main。
- 下一条具体操作：候选覆盖安装到保留旧数据的Android设备，记录实际包版本及列表/首轮sync/入房结果；失败采集该版本诊断再定位，禁止卸载/清数据作为修复。项目[移动交付规则](../../runbooks/mobile-delivery-workflow.md)要求“相关原生编译/集成测试+真实设备相关场景”；无设备仅阻断此验收与后续全量发布。

交接：所有本任务Flutter/打包命令已结束；V:由打包器自行释放，U:已核对所有权后恢复history-icons-performance-2204原映射。下次在候选树跑Flutter前重新核对短盘映射，不能直接以U:运行。最终交付APK SHA复查一致，固定源码候选c1883df7保留独立分支；后续文档commit只记录交付，不改已冻结1904移动输入。

最终审查（2026-10-09T02:30:24.4233404+08:00）：候选SPEC独立检查版本成对、1904冻结输入与规定打包流程，无重要缺陷；历史driver的精确归一化差异由母代理复核，仅版本替换，并由最终QUALITY独立重核通过。QUALITY/SECURITY本地候选PASS，无重要缺陷；实际交付APK身份、固定证书、28门禁、HTTPS定义与清单禁止明文均接受。SPEC后续会话停在pending_init，已中止其重复追问；没有把未返回的补审宣称为额外PASS。此结论仅接受本地候选，真实Android覆盖升级/首次同步/列表/入房未验，不接受生产发布。任务链接在canonical primary全部核对通过；基于原2205的managed文档引用后来rollback记录缺失，不将这一历史链接当移动源码问题。

当前状态：待真机。交付候选APK已提供；生产无写入，现有更新弹窗仍为稳定2206。后续只补DEVICE相关验证，不能为了同输入重复全量门禁；用户手机失败时绑定2207诊断与本候选SHA继续排查。

2026-10-09 03:10+08：按用户追加明确授权，已完成[官网独立测试候选入口](2026-10-09-android2207-candidate-download.md)与CloudFront分发，正式2206及弹窗/iOS2205保持。本候选现可通过官网下载安装；DEVICE仍待实际手机反馈，不能把测试分发当正式发布或手机恢复已验。
