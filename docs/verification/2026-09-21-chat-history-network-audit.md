# 0.3.102 私聊断网关联、历史滚动与搜索调查

## 范围和结论强度

用户报告：Android/iOS均v0.3.102、不同城市，私聊中一方弱网/断网时另一方出现红色发送标记；上滑历史跳页且重复进入仍卡；关键字或日期查历史可卡到需要杀App。尚无两台原设备故障时HTTP/帧耗时/脱敏outbox日志。

核对发行源码`7d1f15b5`（iOS2144）与当前main`8cb445d4`。Android精确build尚未确认，0.3.102曾有多个build；2143源码`eed6bc1f`到2144的本次核心房间/搜索/逻辑时间线文件无差异。当前main已有后续优化，不等于用户安装包已包含。冻结文件身份见[baseline](artifacts/2026-09-21/chat-history-network-audit/baseline.json)。只读调查与隔离探针，未改产品、未发布、未发送生产消息。

## 1. 对方断网与本方发送

**没有发现双方必须同时在线的设计或协议依赖。** 发送等待业务准入、Matrix密钥/成员准备和服务器接收，不等对方设备接收、解密或已读。对方离线不等于退出房间。不同城市也排除了共用Wi-Fi这一假设，但不能证明发送端到具体服务的链路正常。

- 本地红色叹号同时用于`waitingNetwork`和`failed`：`wechat_message_bubble.dart:10–13,84–105`。必须读内部状态才能区分等待恢复与终局失败。
- 私聊每次新发经`room_page.dart:683`→`app_home.dart:295`→`coordinated_direct_chat.dart:123`，有业务resolve/canonical及关系校验，还需自身join、加密、发送权限、双人成员表完整。peer join/invite允许，不查presence。相关服务端`direct_conversation_lifecycle.py:133`仅查成员/加密/power levels，不查设备在线。
- 加密共享密钥走homeserver `sendToDevice`，随后提交密文事件：vendor `encryption/encryption.dart:371`、`key_manager.dart:524,561`、`src/client.dart:3269,3340,3380`、`src/room.dart:927`。lastActive只排序设备。
- **确定的错误分类缺陷：** vendor `src/room.dart:1095–1105`捕获MatrixException后标error并返回null；应用`matrix_e2ee_client.dart`发行2881/2888（main3020/3030）把null一律转MessageSendNetworkException，其“服务端拒绝会直接抛出”注释不成立。服务端拒绝可能被误认为网络失败，抬高**同一设备**全局失败计数；连续失败且无成功复位时可能判离线，不会直接更改异地另一设备状态。
- SDK发送队列先等前项再计发送超时；UI Future.timeout不取消底层请求。黑洞请求占队首是另一个风险，不能将它归因为对方离线。

**未完成：事故确切根因。** 需对齐正常网络端首次红标前后的业务resolve/lookup、Matrix keys/query/claim/sendToDevice/send状态及outbox status/lastError，禁止记录正文、token、密钥。区分准入失败、加密准备失败、服务器拒绝、超时。不能凭相关发生就声称“另一端断网传播到本机”。

## 2. 历史滚动、跳页和重复进入卡顿

**有明确客户端重复计算缺陷；不是历史记录必须如此加载。**

1. 逻辑会话`logical_conversation_timeline.dart:76–90`每次snapshot全量合并、去重、排序。它不实现RoomWindowedTimelineSource，adapter先做全量snapshot再截40/200行。因此显示200行并不代表CPU只处理200行。
2. `sourceRoomId:94–96`每次也调用snapshot。发行`room_page.dart:4578–4606`的索引投影为每条历史消息调用sourceRoomId：N次全量合并排序叠在一次索引更新中。分页前后publish又会触发该路径。main后续9a77f825改增量/400ms去抖，但新消息对象构建在去抖前，冷加载的逐条来源查询风险仍存在。
3. 退出会销毁时间线和页面模型；重进SDK先读数据库最近30条，上滑按60条读本地，没本地结果才请求服务器（vendor room.dart:1458、timeline.dart:134–185）。因此“加载过仍卡”可以是重复读库、解密投影和布局，不等于每次重新下载。
4. 滚动窗口最多200行，每次移动100行，靠锚点恢复维持位置。已有代码等拖动/惯性结束后切窗；未发现可确认的反向offset符号错误。恢复可能经历多帧查找与jumpTo，用户中途继续拖动会取消剩余恢复；这是跳页候选机制，尚不能将用户每次跳页归到单一原因。

### 产品方法及逐帧探针结果

直接调用当前产品LogicalConversationTimelineCapability、TimelineScrollAnchor（相关方法与发行一致），5个合成测试退出0。源码与测试见[scroll工件](artifacts/2026-09-21/chat-history-network-audit/scroll/source_lookup_probe_test.dart)，[原始日志](artifacts/2026-09-21/chat-history-network-audit/scroll/final-run.log)。

- 来源查找：100/1000/3000条逐条查询分别触发100/1000/3000次source snapshot，遍历10,000/1,000,000/9,000,000行。工作站Flutter测试中仅查询循环约16/166/1513毫秒；这是合成环境数据，不可当手机帧耗时或release性能指标。
- 200行重叠窗口切换：原锚点在前8个采样帧未挂载，第8/9帧偏移约+154.7/-154像素，第10帧归零。证明“最后位置正确”仍可经历明显中间跳转。
- 首帧后取消恢复：offset停在14500，锚点仍未挂载。直接模拟canRestore失效，未模拟整页真实手势；页面确有用户滚动使恢复失效的连接，需真机集成确认。
- 早期Flutter cache执行失败日志保留；最终`--no-track-widget-creation`运行成功，不修改产品或原测试。审计期间并行任务又修改room_page，未纳入本次产品变更；发行闭包及本次测量方法身份固定。

## 3. 关键词和日期卡顿

### 关键词：搜索和完整时间线加载耦合

发行`room_page.dart:3032–3053`在结果不足50条时反复_loadEarlier，直到历史耗尽或令牌不前进；每轮currentSearchMessages重新生成全部已加载模型、排序再过滤。300ms防抖仅减少触发次数，未限制单次工作量。此循环与main无行为差异，没有调用独立分页搜索索引来取得本页结果。

直接提取发行搜索闭包，替换分页和投影依赖为合成数据运行Dart（无实际网络）：

| 可用旧历史页，每页60条 | 实际loadEarlier次数 | 累计过滤消息数 | 不命中结果 |
| --- | --- | --- | --- |
| 10 | 10 | 3,960 | 0 |
| 100 | 100 | 309,060 | 0 |
| 500 | 500 | 7,545,060 | 0 |

含初始60条，证明遍历工作随页数二次增长；未包含真实模型、索引与加解密额外成本。不是手机帧耗时测量。证据[探针](artifacts/2026-09-21/chat-history-network-audit/search/search_loop_probe.dart)、[输出](artifacts/2026-09-21/chat-history-network-audit/search/probe.log)、[闭包身份](artifacts/2026-09-21/chat-history-network-audit/search/source-identity.json)。探针退出0。初次合成DateTime本地时区构造过慢的运行主动停止，改UTC测试时间后重跑，不把停止轮算通过。

### 日期：有网络等待、同步计算及独立错误处理缺陷

- 打开日历`chat_search_page.dart:290–305`不取消关键词搜索或防抖定时器；已有后台搜索可继续翻历史，并与日历争用同一主isolate。
- 月份先载入账号索引并遍历已载入事件；未知覆盖做两个串行时间戳探测，各5秒。加载/持久化索引无总超时。选中日期有每物理房间13秒预算，但逻辑会话逐房间串行、无整体预算，且lifecycle等待不被该预算完全覆盖。
- 索引JSON decode/encode、事件转换在主isolate，多个物理房间可能重复处理账号索引。规模/实际耗时未测，不能单凭await认定UI应始终流畅。
- **确定错误：** 发行`matrix_e2ee_client.dart:3445`把探测异常吞成null，上层3369把null当“整月无消息”。最小Dart探针将两次网络调用都替换为TimeoutException，原方法返回(null,null)，原分类分支把9月全部30天标空。证据[输出](artifacts/2026-09-21/chat-history-network-audit/date/probe-output.json)、[原代码身份](artifacts/2026-09-21/chat-history-network-audit/date/original-source.txt)。这证明错误分类，不证明整App硬死锁；可能表现为日期全灰/无法点击。
- 日历仍保留取消和切月回调，未发现普通日期输入必然触发同步无限循环。要解释“只能杀App”，仍需故障时主isolate profile与请求时序。

## 修复优先级与验收建议（尚未实施）

1. 把sourceRoomId变为已有索引的常数时间查找，逻辑时间线做增量合并，杜绝每条消息重排全历史；先断言工作量，再用profile验证帧时间。
2. 搜索独立于展示时间线：本机可检索索引分页、有限扫描预算、取消/续扫、覆盖范围提示；进入日历取消旧搜索。保持本地解密和隐私边界，不把明文搜索转交业务服务器。
3. 日期网络失败保持unknown/error，可重试，不写空日；设置整条逻辑会话预算，保留真正取消能力。
4. 分离网络等待、协议拒绝、权限/成员不完整和超时；保留Matrix错误类型；发送端按txid提供脱敏阶段证据。恢复后同txid续发，不能重复发送或降低加密校验。
5. 用混合长文本/图片的分页，在每帧验锚点而非只验最终位置；覆盖快滑打断、退出重进、1k/10k/50k历史。不同城市的弱网现象须双端故障注入复验，不能拿单端单元测试代替。

本报告不宣称三项真机故障全部复现或已修复。TestFlight2145仍是此前候选，未包含本轮尚未实施的修复。
