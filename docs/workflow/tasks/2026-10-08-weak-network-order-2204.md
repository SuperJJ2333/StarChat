# Android2204 新消息气泡换位与 Telegram 架构对照

## 恢复入口

- 用户授权：对照微信、Telegram 的大群历史与消息展示实现，调查弱网下对方新消息从自己的气泡下方变为上方。补充确认：发生在刚发送或刚收到的新消息随后位置变化，不是旧历史消息互换。
- 状态：研究与本地机制探针已完成，独立证据审查 ACCEPT；不把本次研究或此前历史机制 RED 当成已经上线的修复。
- 关联：[已批准历史连续性调查计划](../../superpowers/plans/2026-10-08-large-history-2204.md)、[此前历史规模调查](2026-10-08-large-history-2204.md)。本次不增加产品功能或改变加密/财务边界。
- 工作树：managed `C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat`，HEAD `25d1d3d943977322cdbd8adb69afe912c0b06d54`；实际已发布 Android0.4.35+2204 源 `3a620495ae048d3e4141f099e1926ecedc8669cd`，managed 中后续语音源修复尚未打包。
- 文件所有权：root 拥有本任务、汇总报告、current-state 新条目和本次证据 root-investigation；两个代理分别只拥有本次证据 telegram-research、order-probe。产品源码只读，只有 order-probe 代理运行 Flutter，统一 U 路径。
- 首次记录时钟：2026-10-08T01:12:52+08:00；精确任务起点未采集。最后阶段时钟：2026-10-08T01:22:50+08:00。下一步：独立复核与文档保存；后续将自动恢复保留原插入时间、尝试时间另记的候选规则转为正式回归，手动重试策略独立核对，确认后保留 Matrix 权威顺序。

## 验收台账

| ID | 场景/预期 | 当前证据 | 缺口 |
| --- | --- | --- | --- |
| T1 | 大群人数、历史数量、每帧工作量分开解释；外部实现只用一手资料 | Telegram 固定 f2908b1413/12.10.6：分页、索引、storageQueue、RecyclerView、普通 ACK 原位更新；微信 WCDB 框架可核实 | 不假称微信私有消息排序代码已知，也不保证 Telegram 所有五万人场景无卡顿 |
| T2 | 确认新消息的稳定身份与垂直顺序变化阶段 | 实际 controller/NetworkStateManager 自动恢复同 txid 重设时间，在 ACK/sync 之前由自己-对方变为对方-自己；3PASS/1候选UX RED，Flutter exit1 | 有确定性合成前置，不等同用户真机单次日志；不是完整 SDK/RoomPage 实测 |
| T3 | 对照服务器顺序校正、重复换位和历史滚动跳转 | 给定权威输入的控制：HTTP ACK 不换位，首次 sync 一次校正，之后四次刷新稳定；旧滚动/恢复机制独立保留 | 不以永久冻结错误顺序规避问题，未证明已确认消息反复漂移；本轮未改源或发布 APK |

## 阶段计时与交接

外部源码研究与本地顺序探针并行。Flutter 实际区间 `01:17:02.7460531+08–01:17:08.4154343+08`，5.6693812s；结束时间不是算法耗时，wrapper exit0记录实际Flutter exit1。外部研究 retrieved_utc=`2026-10-07T17:20:35.2222026Z`（本地01:20:35），未单独采集精确研究起点，不估算其时长。纯调查不运行未改变输入的完整构建/全仓门禁，不读取真实聊天正文、附件或密钥，不改生产配置。

临时产物仅位于 `docs/verification/artifacts/2026-10-08/telegram-order-2204/`；任务记录与汇总在 primary 保存，审查后按 SHA 镜像到 managed，保留 primary 原有 WIP。

九项本地输入前后hash保持；八项blob匹配发布源，matrix client仅后续媒体权限修改，相关顺序映射不变。2050合成outbox日期仅为控制DateTime.now上界选择，不是手机时钟证据。3PASS证明机制及对照，1RED只是拟议“自动重试保留位置”规则，不能称既有规格违规或修复通过。

见[汇总报告](../../verification/2026-10-08-weak-network-order-2204.md)、[探针说明](../../verification/artifacts/2026-10-08/telegram-order-2204/order-probe/README.md)、[外部研究](../../verification/artifacts/2026-10-08/telegram-order-2204/telegram-research/research.md)。本轮新机制与原历史问题分开保留，实际Android仍0.4.35+2204旧成品；未扩大生产发布授权。

独立[规格/证据复核](../../verification/artifacts/2026-10-08/telegram-order-2204/root-investigation/ORDER-REVIEW.md)无阻断项。两项精度建议已处理：云聊天message ID与Secret Chat seqno分开；探针只证明同txid，不扩大为并发重试幂等验证。root已核读fixture/原日志/媒体差异并执行文档链接及索引字节逆变换检查；旧索引tail保全。本任务仅三个文档保存于独立 `codex/weak-network-order-2204` 分支，main与产品输入不变；最终保存commit/精确收尾时间见本次root-investigation闭环metadata。
