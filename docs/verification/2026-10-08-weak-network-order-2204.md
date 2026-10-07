# Android2204 新消息气泡换位与大群客户端实现对照

用户确认本次上下换位发生在刚发送/刚收到的新消息。只读调查复现了一个无需自己消息 ACK 或 sync 的客户端机制：自动恢复网络会重试同一 txid，并重设其本地插入时间，实际 controller 顺序从 `[自己, 对方]` 变为 `[对方, 自己]`。这与用户描述方向一致，但缺少用户手机的安全阶段日志，不能认定其单次现象必定由此触发。

## 本地机制与验证

真实 `RoomTimelineController` + 真实 `NetworkStateManager`，对接仅含合成消息的可控 adapter。先一次 SocketException，使自己消息进入 waitingNetwork；对方新消息随后到达；调用实际网络恢复通知，自动重试仍使用同一 txid。第二次发送 Future 尚未完成、adapter 只有对方消息时，自己消息已被改为晚于最新消息的时间并移到其下方。身份未改变，故稳定 widget key 本身不能阻止数据列表换位。

调用路径：controller `886–909` 恢复通知排水 → `_retry` `1213–1219` 更新时间并发布 → `_nextLocalTimestamp` `1059–1071` 晚于当前最新消息 → `_snapshot` `1030–1038` 按本地时间重新插入。RoomPage `5883–5900` 按实际 messages 顺序反向建列表，使用 stableId 保持行身份。

对照还证明：在给定 adapter 权威顺序 `[对方, 自己]` 的条件下，HTTP ACK 仍保持本地插入顺序；首次自己 `sent && !isSdkLocalEcho` 的 sync 可作一次校正，之后四次不变输入 refresh 保持稳定。该权威输入由 fixture 提供，并未复现完整 SDK 发送入队时序；不能宣称已经证明真实设备反复换位或所有确认顺序。

普通单来源且启用窗口的 logical capability 返回 primary 顺序；跨来源 merge 的 timestamp/ID comparator 不适用于每个普通会话。确认后的 Matrix 顺序不能被永久冻结的本机时间替代。Matrix 官方也要求本地/远端 echo 通过 transaction_id 配对，尽量透明地完成转换，见[本地回显规范](https://spec.matrix.org/latest/client-server-api/#local-echo)。

Flutter 实际退出 **1**：**3 PASS / 1 拟议 UX 规则 RED**。失败规则为“自动重试保留原插入位置”，属于修复设计候选，不是已经通过的门禁或既有规格违规证明。精确运行区间 **2026-10-08T01:17:02.7460531+08:00–01:17:08.4154343+08:00**，**5.6693812s**；2050 合成时间仅用于确定性触发生产时间上界逻辑，不是用户时钟数据。见[探针说明](artifacts/2026-10-08/telegram-order-2204/order-probe/README.md)、[metadata](artifacts/2026-10-08/telegram-order-2204/order-probe/metadata.json)及[原始合成结果](artifacts/2026-10-08/telegram-order-2204/order-probe/order-probe.log)。

九项输入前后 hash 不变，其中 controller、网络管理器、SDK room/timeline 等八项 blob 与实际发布源 `3a620495ae048d3e4141f099e1926ecedc8669cd` 相同；matrix client 只含后来未打包的媒体权限修复，其本次相关映射路径未变。未改产品代码、真实账户或生产状态。

## Telegram 与微信可核实的边界

- Telegram 官方历史接口允许 `offset_id/min_id/max_id/limit` 限定读取范围，见[历史接口](https://core.telegram.org/method/messages.getHistory)。公开 Android 源码有会话/消息索引、分批本地查询、数据库队列和 RecyclerView 单元格复用。因此每次显示/读取的工作量能够与全群人数、全部历史分开；这是架构推论，不是五万人群永不卡顿的性能保证。
- 超级群成员列表也按需获取，避免打开消息页时将全部成员变成界面行，见[官方群类型说明](https://core.telegram.org/api/channel#supergroups)。源码定位、固定 commit、传输及选取片段 hash 见[本次一手研究](artifacts/2026-10-08/telegram-order-2204/telegram-research/research.md)及[研究 metadata](artifacts/2026-10-08/telegram-order-2204/telegram-research/metadata.json)。
- Telegram 普通云聊天/群聊的 message ID 用于消息顺序，Secret Chat 则使用 seqno；pts/seq 用于更新完整性、缺口检测和去重，random_id/updateMessageID 对应本地发送和服务器消息，见[官方更新协议](https://core.telegram.org/api/updates)。不能把 pts 说成气泡排序字段。
- 固定 Android 源 `f2908b14133bbffbf7ab04f641ecb5bfaf533242` 的普通 ACK 分支更新已有 MessageObject、ID 映射、发送状态和现有行；stableId 与服务器 ID 独立。若服务器 ID 已存在，仍有删除重复 pending 行的例外；新消息插入也同时考量 ID/date。不能概括为所有 pending 气泡永不移动，见[ChatActivity 源](https://github.com/DrKLO/Telegram/blob/f2908b14133bbffbf7ab04f641ecb5bfaf533242/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java#L22344)。
- 微信公开的 [WCDB](https://github.com/Tencent/wcdb) 明确用于微信，基于 SQLite/SQLCipher，提供索引、连接池并发访问和批量写入优化。这只能证明数据库框架能力，不能据此断言其未公开会话排序/气泡策略。
- Telegram 普通群属于 Cloud Chats，使用客户端到服务器加密；Secret Chats 才另有端到端加密层，见[官方 FAQ](https://telegram.org/faq#q-so-how-do-you-encrypt-data)。本项目继续保留 Matrix 端到端加密边界，不能通过去掉加密复刻另一产品的成本模型。

## 修复方向与交接

新消息路径的最小候选：自动恢复重试保留原始展示插入时间，重试尝试时间单独记录；手动重试是否重新放到最新位置明确为独立策略；保留同一 txid、发送幂等、在途和权限检查。最终确认仍接纳 Matrix 权威顺序，并覆盖 sync 先于 ACK、ACK 先于 sync、延迟对方消息和确认后的不变刷新。

大历史卡顿另有此前证据：消息 ID 单 JSON 数组的全量读/拷贝/改写，以及显示窗口虽限200但 SDK 已加载源扫描仍随 M 增长。快滑跳转的惯性坐标重基也另有机制 RED。见[此前规模/滚动报告](2026-10-08-large-history-2204.md)。目标应包括数据库分页、客户端增量有界处理、稳定发送确认和滚动锚点保持，分别验收；本次新消息机制不能包揽其余现象。

本轮为研究和可复现机制验证，**未修改或发布 Android 修复**。完整构建和全仓 verify 未运行，因为产品输入未变；尚需真实 adapter/RoomPage 回归及隐私安全真机阶段日志。恢复入口见[任务记录](../workflow/tasks/2026-10-08-weak-network-order-2204.md)。

独立[规格/证据审查](artifacts/2026-10-08/telegram-order-2204/root-investigation/ORDER-REVIEW.md)已 ACCEPT，两项用词修订落实；root核读日志、fixture、输入hash与媒体差异后完成文档一致性复核，不扩大证据范围。索引修改有原tail字节逆变换证明，未合并或推送main。
