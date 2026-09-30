# 双区域选址与真实用户网络观测

## 恢复入口

- 授权：2026-09-26用户“好的，请按照你的计划进行”；随后明确没有测点，允许用真实用户日志，增量放下一次更新。无生产切流/主站/S3搬迁授权。
- 设计/计划：[设计](../../superpowers/specs/2026-09-26-regional-measurement-design.md)、[计划](../../superpowers/plans/2026-09-26-regional-measurement.md)。
- 状态：源码、接收端候选、工具及只读调查完成，最终Flutter4034通过/全analyze0 issue及适用门禁完成。未构建/安装/发布客户端，未部署新接收契约，未启动新口径7–14日观察窗口。回填身份与输入保护结果见[回填收据](../../verification/artifacts/2026-09-26/regional-measurement/integration-receipt.json)。
- 工作树：`C:/Users/Administrator/.codex/worktrees/regional-measurement/StarChat`，分支`codex/regional-measurement-20260926`，HEAD基线b9eca8a419614112b085439445b7fd031027a740；复制80个主目录既有修改为输入快照，保留账号/OTP等其他任务输入。
- 所有权：计划A的移动端文件由network_client独占；B接收端、网络测试与OpenAPI由telemetry_audit独占；C探针/报告及对应infra测试由根代理独占；新增安全收集器`scripts/collect_network_diagnostics.py`、`tests/infra/test_network_collection.py`由telemetry_audit独占。D文档由根代理协调，本次汇总仅独占本记录、验证报告和计划，不覆盖其他业务/账号UI/钱包文件。
- 首次精确准备记录：2026-09-26T22:52:53.569+08:00。更早准备起点未知，不推算工时。
- 最后汇总：2026-09-27 00:28+08:00；详见[验证报告](../../verification/2026-09-26-regional-measurement.md)。
- 下一步：下一次已授权更新先部署兼容接收端、再包含客户端增量；核对实际接收端/包版本和双端设备行为，确认新networks数据到达后才开始7–14日窗口。日常安全收集以独立快照和meta判断覆盖，不凭零样本作主区结论。

## 验收台账

| ID | 预期 | 实现/验证 | 发布/缺口 |
| --- | --- | --- | --- |
| N01 | 每次完成请求分母、成功耗时固定桶、网络方式 | 物理HTTP尝试/完整body/超时与取消/不可变摘要/账号代次/schema2补报已实现；88相邻/最终42专项通过；Flutter全量4034通过，全analyze0 | 下一客户端更新；原schema1缺版本/时间而显式丢弃；无地区/运营商测点，真机待验 |
| N02 | 兼容networks接收，严格元数据/认证/限流 | 新专项红11失败→新旧诊断115通过；契约相邻139通过，OpenAPI check通过；仅诊断路径变化 | 服务端候选，未部署；原认证、限流、16KB、events/frames/accepted保持 |
| N03 | HTTPS探针、安全收集与去重报告 | 工具红18失败→修正分组后19通过；安全收集器54专项/合计73通过，独立安全复审PASS | 工作站路径与服务器自测不是独立运营商测点；收集范围有截断/轮转/上传覆盖缺口 |
| N04 | 边缘/S3草案纠错 | runbook/ADR已修收益、路径信任、健康/日志、ICE/回退及S3旧/新对象覆盖；链接一致性检查完成 | S3仍为待批准提案，未部署边缘、未搬媒体 |
| N05 | 两节点与既有日志只读核对 | HK/SG资源快照、有限探针、远端过滤收集完成；最新20000行/0有效摘要/truncated=true | SG未观测到同栈应用；不能给两主区评分，不替代真实通话/容量/恢复测试 |
| N06 | 规格/质量审查与验证 | 审查修正后PASS；完整verify exit0结束23:42:22，API/worker2862通过/87条件跳过；最终Flutter4034、mobile108/1 skip、工具73及全analyze通过，仓库policy再次PASS | verify早于客户端冻结，复用未变backend/infra输入并补最终客户端/mobile增量；不宣称主区已选出 |

## 证据与计时

工件：[证据目录](../../verification/artifacts/2026-09-26/regional-measurement/)。主目录输入快照在[input-snapshot.json](../../verification/artifacts/2026-09-26/regional-measurement/input-snapshot.json)；客户端来源文件/锁/工具及红绿回执在[client-receipt.json](../../verification/artifacts/2026-09-26/regional-measurement/client-receipt.json)。本轮无新APK/IPA、签名身份或已发布镜像；测试源码hash不能写成线上身份。

| 阶段 | 开始 | 结束/观察时刻 | 类型/并行 | 来源与边界 |
| --- | --- | --- | --- | --- |
| 准备 | 更早起点未知 | 首次精确记录2026-09-26 22:52:53.569+08 | 主动/工具，A/B/C并行 | 不从文件mtime推算此前时长 |
| HK/SG只读 | 起点未知 | 2026-09-26 23:08:05.446/23:08:06.058+08 | 工具，两个节点 | 快照observed_at，不等于完整命令耗时 |
| 完整verify | 2026-09-26 23:11:57.906+08 | 2026-09-26 23:42:22.242+08 | 工具，与客户端实现并行 | verify-start/result实录；墙钟30分24.337秒，exit0；隔离开发.env来自版本化example，无生产秘密 |
| 客户端最终analyze/专项 | 2026-09-26 23:48:24.527+08 | analyze23:48:27.288、专项结束23:48:30.775+08 | 工具 | client-final-timing回执；以前阶段只记录tool wall duration，没有完整起止 |
| 安全收集 | 2026-09-27 00:16:21.330+08 | 2026-09-27 00:16:23.083+08 | 工具 | collection-result exit0；元数据采集UTC16:16:21.068Z |
| 最终Flutter全量 | 2026-09-27 00:16:21.321+08 | 2026-09-27 00:22:47.106+08 | 工具，与采集/工具并行 | flutter-full-test-result：4034通过、exit0；完整墙钟6分25.785秒 |
| 最终工具专项 | 2026-09-27 00:20:47.877+08 | 2026-09-27 00:20:50.772+08 | 工具 | tools-final-result/log：73通过、exit0；reporter1.29秒与总命令墙钟不同 |
| 最终mobile边界 | 2026-09-27 00:23:15.752+08 | 2026-09-27 00:23:21.714+08 | 工具，与全analyze并行 | 108通过/1条件跳过、exit0；reporter4.97秒 |
| 最终全analyze | 2026-09-27 00:23:15.637+08 | 2026-09-27 00:23:38.431+08 | 工具 | No issues found、exit0；reporter19.5秒 |

上述并行区间不相加为总工时；主动执行、外部等待及部分返工起止未完整记录，均为未知。测试命令、数量、失败保留及证据身份见验证报告。

## 交接与回退

本轮交付源码/接收端候选/工具与只读证据，当前生产配置、DNS、TURN列表、数据与媒体位置保持。没有购买新资源、创建隧道、发布安装包或执行财务写入。仅24项归属文件回填；80项继承输入逐文件hash保护，另两项原干净tracked文件与HEAD复核。最终manifest/source/destination身份以回填收据为准；不复制脏树、生产.env或其他任务改动，不重复已完成且未变输入门禁。

旧服务端422时客户端停用网络扩展、继续原事件/帧通道；正式发布先接收端后客户端。安全收集器经既有strict jumper，只读取固定容器，远端验证后才导出networks；默认72h/20000行，最大72h/100000行，净化输出另限16MiB/20000摘要。无样本、tail截断、export_limited及轮转留存未知都不能解释为零失败率；每天保留独立快照并按sample_id去重。

真实用户窗口从包含此增量的版本上线且确认新数据到达后开始，不从源码完成或旧诊断首次出现日开始。7–14天需覆盖晚高峰和周末；实际采集频率先按日志增长、轮转和tail上限评估，每日独立快照不保证全天覆盖。仍缺地理/运营商归因、HK/SG同栈对照、消息端到端、通话中央采样和恢复演练，因此当前报告`evidence_insufficient`，不能启动主区迁移。
