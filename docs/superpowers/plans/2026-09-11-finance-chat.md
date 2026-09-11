# 红包、转账与点钻账单实施计划

> 执行：subagent-driven-development；Astra 规划并亲审实际 diff，显式 gpt-5.6-terra 执行测试及修改。用户已授权连续实施，每批审查后推进。

**Goal:** 根据业务权威状态呈现本人红包领取、转账收款及完整点钻账单，保持财务与 E2EE 边界。
**Architecture:** 业务 API 提供用户隔离的只读投影；Flutter 以账号隔离、请求合并的状态层更新可见卡片，详情操作后刷新；账单采用服务端筛选与游标分页。
**Tech Stack:** FastAPI / SQLAlchemy / Decimal；Flutter Cupertino；现有 frontend HTML 示例与 UI registry。

## 授权、基线与设计决定

- 工作树 `.worktrees/performance-20260911`，基线 a07c996a。保留现有三处无关修改；不 clone/pull/reset/push/部署/生产迁移；真机交由用户。
- F01 事务原子性、F06 群权限审计约束继续有效。本任务编号 FC01–FC08 如下。不改分配算法、手续费、金额公式、账本 schema、支付密码与审计/outbox 写入路径。
- 已证实：RoomPage 固定 available/pending；转账 accepted 标签未区分身份；bestLuckRecordIndex 无群/模式/终态门槛；创建群红包无人数上限；缺少 CAIBI 用户账单查询。
- Matrix 卡片仅保存业务引用；状态/金额从业务 API 获取。领取状态以鉴权用户的领取记录优先于全局终态。群 RANDOM 仅 COMPLETED 或已到期显示最佳，最高金额精确比较，平手按领取时间先后。
- 当前加入群的成员数包括发送者；服务端成员权威不可达时创建失败且不扣款；合法幂等重放不因群人数后来减少而失败。
- 转账收款时间从终态 updated_at 投影；账单 ID 为实际 LedgerTransaction.id。全部账单仅查询本人 CAIBI 分录，不能混入 USDT 钱包账本；未知类型仍显示“其他”。
- 类型白名单、起始时间包含/结束时间不包含、UTC API、本地时间展示；关键字长度受限且仅匹配已授权业务元数据；created_at/id 稳定倒序游标，分页上限100。
- UI 复用现有微信风格令牌，HTML 示例为视觉记录。无当前微信截图/版本，不声称像素一致。用户给定状态规则为验收依据。

## 验收用例（实现前确定）

| ID | 必须验证的行为 |
| --- | --- |
| FC01 | 同一红包不同用户各自领取状态；别人领完/过期不能显示本人已领取；已领取再点直达详情；异步失败可重试且账号切换不串状态 |
| FC02 | 收款方 accepted 显示“转账已收款”，发送者“对方已收款”；待收款/退回/过期身份文案正确；再次进入显示金额、说明、发送及收款时间 |
| FC03 | 普通/专属/私聊不显示最佳；群 RANDOM 未完成不显示；完成/到期显示；精确金额比较及平手稳定 |
| FC04 | 群人数相等允许、超出前后端拒绝、含发送者；权威失败/非成员拒绝且无扣款；幂等重放及私聊不回归 |
| FC05 | 账单详情含真实账单 ID 可复制、状态/说明/时间/金额；他人 ID 404；无对应入账记录不伪造 ID |
| FC06 | 全部本人 CAIBI 红包/转账/提现/充值/其他流水；USDT 隔离；类型/时间/关键字组合筛选；同时间分页不重复不漏；非法条件明确报错 |
| FC07 | 列表加载/空/错误/重试/分页；快速改筛选及切换账号不回填旧结果；卡片请求合并且不随每个输入字符重发或全量列表重建 |
| FC08 | Flutter 与 HTML 示例/registry 同步；支付密码、账本平衡/幂等、群权限、现有聊天性能路径回归 |

## 批次与文件所有权

### B1 服务端红包（FC01/03/04，关联 F01/F06）
- [x] Terra：先写失败用例，运行确认，再修改 `modules/redpacket/{service,membership}.py`、`api/redpacket.py` 及 `tests/business_api/redpacket/`。
- [x] 增加兼容字段 room_id、viewer_claim、server_time / 最佳展示条件；保持旧字段。单次权威成员快照检查创建人数和发起人身份，幂等路径优先。
- [x] 测试：红包服务/API、权限、原子性；实际命令/退出码/日志写 finance-chat 证据目录。
- [x] 关联 fixture：`tests/business_worker/test_redpacket_expiry.py`、`tests/business_api/audit_pg/test_f01_f02_transactions.py`、`tests/business_api/ledger/test_supply_invariant.py` 补群创建成员权威，保留原过期/原子性/供给断言；生产 worker 过期路径不修改。全量回归补充 `tests/business_api/test_payment_pin_api.py` 的静态Matrix成员夹具，保留PIN与重放断言。
- [x] Astra 检查代码、接口兼容、失败无财务副作用后批准 B2。

### B2 服务端账单及转账投影（FC02/05/06）
- [x] Terra：`modules/ledger/` 新只读查询服务、`api/ledger.py`、`modules/transfer/service.py`、对应 ledger/transfer 测试。共享 API/OpenAPI 文件仅此批写。
- [x] 明确所有现有 CAIBI scope 类型映射；以本人分录聚合，不暴露其他账号分录；转账关联通过实际托管账号/账本事务及业务接口，禁止猜造账单 ID。
- [x] 增量 OpenAPI/契约更新；过滤、权限、精度、稳定分页红绿测试；Astra 复核 SQL、跨模块边界和真实调用链。

接口约定：`GET /ledger/transactions/me?kind=&start_at=&end_at=&q=&cursor=&limit=` 返回 `items,next_cursor`；`GET /ledger/transactions/me/{transaction_id}` 返回单条。条目至少 `id,asset,amount,kind,reason_code,created_at,status,note,business_id,transfer_amount,fee,accepted_at`，无适用业务字段为 null。`amount` 为本人的有符号实际分录合计（付款包含既有手续费），`transfer_amount` 为转账本金，两者不得混淆。类型 `redpacket,transfer,withdrawal,deposit,other`；所有现有 CAIBI 事务均可在无筛选列表找到。

转账详情增量返回 `accepted_at`（仅 ACCEPTED 时的 updated_at）、`bill_id`（本人实际相关账本事务，否则 null）。通过 `PLATFORM_TRANSFER_ESCROW:<id>` 的真实分录与本人分录共同定位，不通过时间近似匹配；接收方接受前无本人账单。创建/接受/退还响应保持兼容，客户端成功操作后再次 GET 权威详情。

源码确认现有点钻充值/提现来自 `wallet.conversion`（USDT_TO_CAIBI/CAIBI_TO_USDT），退款来自 `wallet.conversion_reversal`；它们仍是点钻账本的既有记录，本任务仅展示，不增加或调整换算。退款显示提现退回且保留原始 reversal 关联，不能误标成一次充值。跨模块元数据通过公开只读应用方法批量查询，避免逐行 N+1 与新增跨模块写操作。

### B3 Flutter 状态及详情（FC01–05/07）

分步执行顺序：B3a纯状态映射/两类卡片/红包详情规则 → B4a账单API客户端及账单页面 → B3b聊天可见卡片状态订阅、红包跳转/人数限制、转账详情及账单导航 → B4b HTML/registry 对齐。先建目标页面再接入口，每步都保持可编译，不留下临时占位跳转。
- [x] Terra：`core/business_api_client.dart`、`features/{matrix,redpacket,transfer}/`、新增 `features/finance/` 状态投影、`ui/finance/` 及对应测试。
- [x] 请求按 sessionEpoch/业务用户 ID/资源 ID 隔离并合并；仅必要可见卡片刷新，详情操作后失效；注销、异步竞态、失败重试有测试。禁止每个消息/字符触发历史全量加载。
- [x] 群人数单独传含本人总数，不复用排除自己的专属接收人列表长度。已领取直达详情；收款详情含账单入口。
- [x] 测试金额/角色状态纯逻辑与 widget 交互；Astra 亲审生产 RoomPage wiring 与路由。

客户端接入细节：卡片状态监听局限在卡片子树，不调用聊天页全量 setState 或 timeline.refresh 伪装财务刷新。RoomPage 已有 `_joinedMembers`（过滤 isJoined 并按ID去重），群上限使用它并刷新成员资料；专属选择列表与人数校验分别传参。API已有 `sessionEpoch`、`sessionInvalidations`、`currentUserId()`（业务ID，非MatrixID），复用这些隔离身份及异步返回。未取得权威详情不伪造“已领取/已收款”；失败可重试。红包本人已领取直接打开领取详情；未领取保留拆红包交互。BigInt分单位比较最佳金额，保留字符串金额，不新增double金额计算。可用 `WeChatColors.redPacketMuted` 表达已领取封面，不新增无登记色值。

### B4 Flutter 账单与 HTML 对齐（FC05–08）
- [x] Terra：新增 `features/ledger/` 页面/控制器与测试；完成列表服务端筛选/搜索/分页，复制真实 ID；新增 UI 必须在 `frontend/` 与 `packages/ui-contracts/changliao-component-registry.json` 同步。
- [x] 同一 Flutter 文件串行；可独立 HTML 批次才启用第二个显式 Terra，不超过两执行者。
- [x] 筛选可组合类型、时间和关键词；自定义日期结束日转换为下一日本地零点再转UTC（API结束不含），取消不提交；搜索防抖且改条件即递增generation，旧请求及旧分页不得覆盖新条件。账单详情转账本金/手续费/实际收支区分，长ID可复制且小屏/文字放大不溢出。
- [x] Flutter focused tests/analyze、UI contract、frontend npm test；预检 verify.ps1 后执行适用门禁，已知基线失败逐项判断关联性，不能当成功。

### B5 最终审查与交付
- [x] Astra 汇总实际 diff、调用链、测试证据及跨模块回归；复查 FC01–08 台账。仅本地成果，未测试效果如实写明。
- [x] 更新任务/验证记录：实现范围、文件、复现及根因、命令结果、未覆盖真机/多端效果、微信已知差异。

## 验证与证据

证据目录 `docs/verification/artifacts/2026-09-11/finance-chat/`。Windows pwsh7/UTF-8；Python py -3.12；Flutter C:/src/flutter/bin/flutter.bat --no-pub，编译测试串行。前任务全量 Flutter 2199通过/29钱包失败，后端1821通过/51跳过/9失败仅为历史基线；本次财务关联失败需重新判定，不能自动豁免。


## B3b 接入补充（Astra 调用链审查）

- `RoomPage._openTransferDetail` 目前在settled及关闭两次全量刷新timeline，删除该财务专用刷新，改为对应finance reference状态失效/刷新；其他聊天历史刷新保持。
- `showRedPacketClaimDialog` 的production调用位于RoomPage。点击先读取最新权威detail，viewer_claim非空直接push领取详情；否则保留现有拆红包。快速双击只打开一次，所有await后检查mounted与账号epoch。
- 卡片状态读取以只读gateway注入测试；每个RoomPage持有一个账号绑定store，key为业务kind/id，最大200个无订阅LRU条目，合并在途请求，限制并发4。订阅通知只触达当前card。
- 可见性复用`MediaVisibility`，仅可见且前台路由active时读取；可见非终态以15秒新鲜期补查，离屏/后台取消定时器，返回/点击强制权威读取。终态在同账号内可复用；本人领取记录优先全局状态。网络失败保留已核实状态并显示重试提示，无缓存则中性加载态。不能伪称服务端推送即时同步；多端外部状态在可见刷新周期内或点击时收敛。
- `RedPacketController.load` 当前await后直接notify，需补dispose/generation守卫；账号失效时通过可选session接口/安全gateway阻断旧数据填回，保持既有测试fake接口兼容。
- `_showRedPacket` 的专属收款人列表须过滤joined且排除本人；总人数使用包括本人且去重的`_joinedMembers.length`。发送前刷新成员快照，UI限制与服务端最终拒绝均有明确文案，不能用客户端人数取代服务端权威。
- 详情页只读跳转和领取/接受动作保留原业务API。接受后GET返回真实bill_id，失败应保留可重试状态；不以Matrix senderId替代business viewerId。

## B4a2 页面与验收细化

- `LedgerListPage(gateway)` 使用 `LedgerController`；标题“全部账单”，类型选项“全部/红包/转账/提现/充值/其他”，搜索框、可取消的起止日选择、清除日期入口。纵向惰性列表；分页期间保留旧行，错误提示与重试位于尾部；首次错误/空状态独立。账单行显示类型、真实金额、时间、可用说明；点击传真实id至详情。
- `LedgerDetailPage(gateway, transactionId)` 每次进入GET，加载/失败重试/会话终止守卫；标题“账单详情”。转账本金、手续费、实际收支分别展示，不把收款方的到账金额误减发送手续费；显示“转账说明”“转账时间”“收款时间”“账单ID”，无收款时间用“尚未收款/未收款”，其他类型使用“入账时间”并不捏造链上完成状态。
- ID用可换行文字和带语义label“复制账单ID”的icon，Clipboard调用成功后显示已复制反馈，失败有明确反馈；下方“全部账单”可跳转，若来自列表可正常返回列表，避免重复路由堆叠。
- 金额仅使用API字符串，展示两位小数，不经double。时间合法ISO转本地 `yyyy-MM-dd HH:mm:ss`，无效值用“--”。页面用可滚动区域，320px宽/2倍文字测试无overflow。
- widget验收：真实控件切type并输入q、选/取消date后查看fake gateway组合参数；旧response不重绘；加载更多及重试；行→详情→复制/全部账单路由；会话失效/销毁后响应忽略。UI不得只新增未引用的组件或伪数据生产入口。
- B4b允许同步`tests/mobile/test_ui_component_registry.py`中过时数量与新增映射断言；保留校验强度。HTML fixture也必须按选中真实fixture ID及控件条件驱动，不得以固定预设导航冒充筛选/分页/详情。

B3b人数接线注意：`_refreshJoinedMemberCount()`吞掉网络错误以保护导航标题，不能把它当创建权限证明。创建仍由服务端最终校验。页面打开/发送前使用 `roomLease.refreshRoomInfo()` 的joined去重快照（包括本人）更新前端限制，异步后检查mounted；群成员上限与既有500上限取较小值。`ChatRedPacketController._error`须透传人数超限等明确业务错误，不能落入泛化“检查余额或网络”。发送过程继续使用原ChatPaymentIntent，不移动PIN授权/财务创建顺序。
- B3b红包领取详情补可重试错误、明确红包状态（领取中/已领完/已过期/已撤回）及页面生命周期/账号失效保护。联系人加载返回也按同一账号守卫，不能旧账号备注回填；不修改共用拆红包按钮文案来冒充详情状态。
- B3b转账接受/退还：业务写成功即保留成功返回状态并失效卡片，再GET补真实bill_id。若后续GET失败，提示详情更新失败并可重试，不把已成功收款说成操作失败或恢复待收款按钮；无bill_id时不伪造账单详情入口，仍可进全部账单。mounted/epoch通过后才调用上层onSettled，不全量刷新聊天时间线。

### B3b1 审查后拆分

1. A 会话安全：held身份请求→epoch变化不继续详情；same-epoch失效拒绝旧响应；异常路径epoch变化结束会话；dispose迟到响应不通知/开timer；结束后全部公开读取/重试入口不发请求。范围store/test。
2. B 可见调度：每订阅独立lease，最后可见者离开才停止；4并发，第5队列，离屏撤销可重新入队；15s非终态可见刷新，本人已领取但群未终结仍刷新；ensureFresh等待实际完成，禁止隐式永久可见。
3. C 缓存与卡片：LRU按读取/访问更新，完成请求后也执行无订阅条目上限清理；卡片换key继承当前可见状态，dispose释放lease；中性加载与失败重试不能冒充待收款。状态仅局部子树通知。
4. D 页面接线：RoomPage、红包详情生命周期、群人数、转账收款页分小批串行；只在前置网关及页面验收后接入口。

每个小批保留实际红绿证据与scoped analyze，主代理读代码/日志后再推进。历史测试通过不覆盖后续变更；接口改变同步当前引用，禁止留下不编译的过渡状态。
- RedPacketViewGateway 既有fake不具session接口；可在controller/page可选识别现有core `BusinessSessionMonitor`（BusinessApiClient已实现）作epoch/invalidation保护，避免强迫所有旧fake新增无关方法或修改core权限接口。详情展示到期状态同时考虑可信server_time/expires_at，不能用设备时钟推算财务终态。
- 转账receipt可增加独立可测试gateway及Business适配器，并保持旧构造参数兼容；字段引用 ledger 已有公共gateway/pages，真实 bill_id 缺失时不显示可点击账单详情。受保护写操作仍走原业务API。
- Store失效语义：业务操作成功后invalidate(key)不能被已有flight静默吞掉；标记该key失效/版本，拒绝旧读覆盖新操作，合并一次后续读取。离屏失效只标记dirty，重新可见/点击时再读。ensureFresh必须等待相应实际完成并返回可核查state；临时点击读取不遗留永久visible标志。最大4并发包含身份读取与详情读取整个请求，运行中的离屏任务仍占槽直到返回。

## B3b2/B3b3 审查推进

- 转账controller已由Astra亲读source、10个回归测试及16项组合绿日志。load/retry在写操作期间合并等待，已成功写不被后续GET失败或observer异常反转；same-epoch失效、dispose、发送方禁止接受均有断言。页面及RoomPage仍未完成。
- 红包controller第一轮4pass不满足验收，Astra发现测试仍有错误override且未覆盖held claim跨账号；要求新增真实断言并scoped analyze。红包弹窗原status==null可领取、任意非OPEN写“已领取”亦为待修根因。
- 后续群人数前端采用独立总人数输入及发送前异步快照回调，包含发送者，和专属收款人列表分离。controller在验证开始即占用creating防双击；权威快照失败须明确提示且不能继续create/PIN。sheet初步检查 min(totalJoined,500)，controller发送前再检查变化；服务端仍最终校验。异步离开页面不得继续新建支付或notify已dispose对象。
- RoomPage接线须在详情页面与群发送接口稳定后由单个Terra串行拥有；每个房间一个FinanceCardStore，生命周期销毁。点击单飞、await后mounted/epoch检查，按key ensureFresh→viewer_claim详情/领取弹窗；onSettled及关闭仅invalidate该key，不timeline.refresh。

### B3b3 生产入口的可测试落点

为避免对大RoomPage注入多个测试专用服务，允许新增 `features/finance/finance_message_entry.dart` 作为真实可测试入口widget：接收房间store、api、业务kind/id及红包发送者展示信息，内部复用FinanceMessageCard；点击临时lease.ensureFresh后做session/mounted守卫、单飞路由，按viewer_claim直接详情或拆红包，转账push收款页面。写成功及关闭只invalidate对应key。RoomPage两分支必须实际实例化此入口，房间init/dispose负责store，删除旧弹出转账和timeline.refresh专用函数。针对这个真实入口以BusinessApiClient+MockClient测试点击、重复点、角色/详情跳转、领取后失效、失效账号无导航；再亲审RoomPage调用链/编译和性能相关回归。不得为测试新造与生产不相连的导航函数。

## 最终本地验收

B1–B5代码实施与本地审查完成；勾选表示执行完毕，不表示全仓门禁全绿或真机通过。完整Flutter2310通过/29既有失败，analyze与Android ARM64源码编译通过；后端/npm/Python mobile失败及环境阻断已记录。生产部署、最终APK重建签名及真机不在本次完成项。详见[最终审查](../../verification/2026-09-11-finance-chat-review.md)。
