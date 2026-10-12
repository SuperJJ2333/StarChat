# Android2215 发布准备：独立规格/领域审查

结论：**PASS_PREPARATION_ONLY**，候选 `c1b1ccd777d7ef11a1a1af956547b43bbf89d573`。先完成本规格/领域审查，再进行质量安全审查。没有本次真实 APK、final package、freeze 或可执行发布 review 的批准。

## 范围与要求

本候选仅增加 `docs/verification/artifacts/2026-10-12/android2215-release/`，承接已授权的 Android 0.4.46+2215 图片/视频修复发布。产品修复、debug、正式构建、固定签名及实际发布由 root 负责。不是新授权询问，也不扩大本轮执行范围。

| 验收项 | 独立核查 |
| --- | --- |
| 发布目标 | 包名 com.liuhetong.mobile、arm64-v8a、0.4.46+2215、standard-arm64-release、固定75b31证书；拒绝旧2214/0.4.45及旧包SHA |
| Android变化 | 仅download.html、downloads/android-release.json；仅latest_version/latest_build/update_notes三个设置 |
| 保持边界 | iOS0.4.44+2213五设置、双方minimum3和安装URL、其他五静态文件、旧APK和其他ABI别名、35容器身份、schema0095、永久guard/probe及桶策略 |
| CDN | 旧16条规则及所有其他分配字段不变，只从旧2214 HK路由克隆一个2215精确路径，追加为17；ETag CAS |
| 缺失成品 | APK/receipt/steps/source manifest/lock/三类真实gate均必填；没有默认新APK身份或伪造通过记录 |
| 来源绑定 | 实包SHA/字节数、source commit/manifest、lock、gate文件、runtime每文件和tar成员、最终freeze与两份最终审查报告逐项绑定 |
| 默认执行 | 无execute时仅本地计划；真正阶段须精确package与operation_id绑定的独立review；准备审查不生成这种执行review |
| 本地回填 | 只生成两文件review-only回填计划，不写仓库；实际发布后仍需用当次本地raw/Git/生产捕获身份核查CAS，不盲目覆盖已有差异 |

## 证据与领域边界

作者基线捕获时间为2026-10-12T11:59:00.230878Z（HK）及11:59:27.178466Z（SG）；它们只是冻结事实。本审查未重新连接服务器，不能称现在仍无漂移。runtime阶段必须重新读基线；任何容器、guard、schema、版本、静态或云状态差异都必须停止并说明，不能静默重冻或回滚别的服务。

设置通过现有 `SettingService.set_many` 在事务与审计边界内操作，不直接写AppSetting，不修改财务/鉴权/E2EE/native逻辑。新旧版本/说明的差异有测试；`transact`函数、四个源码依赖及捕获的API镜像/schema精确一致，允许复用历史隔离PostgreSQL六例行为证据。历史6PASS/8.16s不记为本轮新PG运行或当前数据库验收。

作者版本RED为目标/基线不符的1FAIL+15ERROR，另14例原有通过；永久guard RED为五个应抛异常而未抛的子断言，未以导入缺失冒充RED。独立新候选32例通过，详见第二份审查。

规格结论只覆盖准备框架。最终真实APK、媒体发送/ACK、共享/native/实包三门禁、实际source-backfill与最终freeze必须另行审查。16KiB兼容、全ROM/OEM推送、功耗与端到端SLO、iOS签名/真机等未测事项不因本准备通过而关闭。
