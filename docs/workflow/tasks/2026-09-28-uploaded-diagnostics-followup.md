# 用户上传诊断日志复查

## 恢复入口

- 目标和授权：用户要求检查当前已上传的诊断日志是否还有问题。执行生产只读、服务器内脱敏汇总；不改业务数据、服务、DNS 或客户端发布。
- 流程与关联：[生产工作流](../../runbooks/admin-production-workflow.md)、[移动交付工作流](../../runbooks/mobile-delivery-workflow.md)、[诊断保真批准计划](../../superpowers/plans/2026-09-28-client-diagnostic-fidelity.md)、[本轮报告](../../verification/2026-09-28-uploaded-diagnostics-followup.md)。
- 当前状态：检查完成；已确认真实超时/同步/媒体/慢帧样本及 Android 2190 逐请求明细缺失、批次容量阻塞和遥测丢失。仅调查，没有新代码或发布。
- 文件所有权：Root 为本任务记录、报告、`current-state.md` 和根层证据；并行调查分别只拥有 `live-triage/`、`network/`、`sync-media-perf/` 子目录。当前工作目录 `D:/pythonProject/outsource/StarChat`，本任务只读无需新工作树。
- 最后更新时间：2026-09-28 19:34+08；19:24:10+08 固定主快照，报告整理晚于该时刻，不把新日志混进冻结结果。
- 下一条可执行步骤：依既有诊断计划为 Android 详细请求记录保留批次容量，补饱和队列/客户端15KiB/服务端16KiB/422 回退测试，并确认端上请求是否已排队或扩展关闭；在下一新 build 上线后用真实上传证明 `network_requests` 到达且丢失受控，再沿同请求 ID 调查链路。iOS 要等包含同等诊断的新 build 后复核。此调查本身不选香港/新加坡主区。

## 验收台账

| ID | 范围与预期 | 证据和结果 | 状态/限制 |
| --- | --- | --- | --- |
| D01 | 现网身份、日志时间窗和接收完整性 | [固定摘要](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/live-triage/summary.json)：当前 API 镜像 `2b847…`，首日志 16:05:19、截止 19:24:10+08，115,543 行、245 接收、0 拒收/污染；2 个冲突操作身份隔离 | 当前容器窗口已完整分段扫描；客户端丢失和旧容器缺口保留 |
| D02 | 按版本/平台辨别网络故障 | Android 2190 154 个 API 超时终态；[网络摘要](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/network/network-aggregate.json)为 Wi‑Fi 154/17,732、mobile 25/6,548 超时 | 不同口径/窗口不相加；没有用户/地区/运营商/入口归因 |
| D03 | 请求明细是否覆盖新版超时 | [批次字段](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/network/batch-field-count.json) 2190 110 批均无 `network_requests`；[容量](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/network/batch-capacity-count.json)相邻 109 批中 108 批事件+操作占满20；[冻结源码身份](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/source-attribution.json)匹配客户端装箱顺序 | 已证实满额批次无明细槽位；全部批次仍需端上核查请求是否排队或扩展降级 |
| D04 | 同步、媒体、帧和丢失 | 全容器 2190 同步失败72、媒体失败2、83 独立 loss 样本报告丢 3,612 操作/198,259 帧遥测；[专项](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/sync-media-perf/README.md)有独立滚动窗口的阶段/慢帧统计 | 遥测帧丢失不是 UI 掉帧，抽样数据不能算总体故障率 |
| D05 | 服务端关联与健康 | [请求关联](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/network/request-overlap-aggregate.json) 45,680 服务端时间线皆完成、无可见 5xx；5 个 iOS 超时有同 ID 服务端完成；[运行态](../../verification/artifacts/2026-09-28/uploaded-diagnostics-followup/api-followup-health.json) healthy/0 restart | 分片有行数/导出上限；服务端完成不保证手机收到，409 根因未定 |

## 版本、证据和阶段计时

Android 正式发布 `0.4.21+2190` 的冻结源码文件哈希与本轮检查的 `chat_diagnostics.dart`、`network_diagnostics.dart` 完全一致；生产接收端仍为 `sha256:2b847ef70e0257f4ba52e663812112d7664016ff427d454c32630da1b0c89a63`。iOS 仍为 `0.4.20+2189`；18:02+08 替换签名团队的包沿用同 build，日志无法按 Team ID 区分。原始用户日志不出服务器；曾用于闭合请求关联的工作站逐请求临时副本已删除，最终工件不含请求 UUID、用户信息、IP、URL、正文或凭据。

| 阶段 | 可证起止（香港时间） | 并行组和结果 | 限制 |
| --- | --- | --- | --- |
| 恢复上下文与基线 | 约19:09–19:11 | Root 阅读当前状态/既有核验，确定当前容器重建边界 | 首条人工动作的精确秒数未保存 |
| 生产只读扫描 | 约19:10–19:24:10 | triage/network/sync-media-perf 并行；服务器内分片、按版本平台聚合和请求关联 | 各独立采集截止不同，不能拼成一个原子全量快照 |
| 证据校验与报告 | 19:24:10–约19:34 | Root 对冻结源码、汇总口径及最终文件作一致性检查；独立只读审查指出并闭环容量因果边界与15KiB客户端默认预算 | 外部真机和客户端弱网复现未执行 |

可证工具读回从约19:09:55至19:34:07+08，约24分钟12秒；用户消息到首个读回的时间未精确保存，不把它估进墙钟。并行子任务耗时不可相加。没有部署、重启、业务写入、原始日志导出或保留的隧道；无恢复操作需求。`--tail 100000` 会缩短可见时间窗，后续不要把滚动批次数下降解释为改善。

文档校验：本任务报告、任务记录及 `current-state.md` 新增段落的本地链接均存在；证据 JSON 的批次分组/七个时段合计均为 245，八个网络摘要分组的结果计数逐项等于 `attempts`，最终工件未检出请求 UUID、IP/URL/凭据字段。全量扫描历史 `current-state.md` 时仍有旧条目的缺失相对链接（例如 2026-09-21/22/23 审查记录），本任务未修改那些条目，不能把该全量检查称为通过。固定主摘要 SHA256 `be6bc12fbbf93f0468e19b3774180c577e43cc23356f10b0812e343aca1f65b9`；网络摘要 SHA256 `ffa2457a08be30bbd703660fcd3be387e4c2fa2aaac80086ecc5b15983650a92`。
