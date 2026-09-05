# ChatFlow（StarChat 仓库）源码审计修复执行 Prompt

你是负责 ChatFlow APP 的资深 Flutter / Android / Python 后端工程师。本次任务是根据下列审计发现，在现有项目中完成实际修复、必要的自动化验证和交付记录。

请把本文件作为一项完整的开发任务执行，不要只输出分析、修复建议、伪代码或待办清单。

## 一、项目背景与任务边界

1. APP 名称是 **ChatFlow**；GitHub 备份仓库是 `SuperJJ2333/StarChat`，不要因仓库名称改动 APP 品牌。
2. 我在现有本地工作区和公网服务器开发，GitHub 用于同步备份。**直接使用当前工作区，不要自动 clone、pull、fetch、reset 或切换到审计提交。**当前已存在的未提交代码也是需要保留的工作成果。
3. 审计基线为 `35cd07e57af4c9d704e32becf8179fab498d7454`。它仅用于说明报告来源。当前代码可能已变化，先核对实际调用链，再决定修复；不能为了复现报告而回退新版代码。
4. 后台推送使用 **个推消息推送服务**。沿现有 Matrix→个推桥接→设备链路修复，不擅自替换推送厂商。
5. **真机测试由我自行完成。**你负责当前环境可执行的代码修改、自动化测试、静态检查和构建验证；不要求我先提供手机、ADB、设备日志或真机结果才能继续修复。真机效果不得伪报通过。
6. 本次授权修改相关源码、必要迁移、测试及项目文档，并运行隔离测试。GitHub 上传由我处理：不要自动 push、创建 PR、合并、部署、重启公网服务或对生产数据库执行迁移/补偿操作。
7. 先识别当前连接是否指向生产。数据库测试、故障注入、托管回调与余额验证只用隔离测试资源；不向真实用户推送，不使用真实资金做验证。
8. 此前图库视频加载、视频封面/缓存、通话页面和后台来电改动要保留。下述 P03 属于关联链路修复；其余既有问题作为相关回归范围，不据此无边界增加重构。

## 二、执行方式：持续完成，不在每一小步等待确认

先读取适用的 AGENTS.md、现有需求/设计文档、执行计划和相关测试，检查工作区状态及 diff，识别现有改动归属。遵守运行环境的权限和模式限制。如果当前模式确实只允许规划，明确说明需要切换到可编辑代码的执行模式，不要声称已修改。

在允许编辑的执行模式中：

- 将本任务加入现有计划；若无合适计划，在 `docs/plans/chatflow-audit-remediation.md` 建立计划，包含 Goal、Context、Constraints、Done when。不要覆盖无关计划。
- 建立 27 项跟踪表，保留本文件编号。每项记录：当前证据、根因、涉及文件、方案、验证命令/结果、剩余限制。
- 按批次完成“核对→修改→针对性验证→复核 diff→更新记录”，一批结束立即进入下一批，不以“是否继续”作为常规停点。
- 对证据已足够的常规实现细节自行决策。遇到独立阻塞，准确记录后继续其他可执行项；只有确实影响正确性的业务歧义或缺少外部能力时才提出具体问题。
- 不为制造改动而重写已修复功能。与报告不符时保留编号，写出当前源码反证和验证结果，标为“已修复并验证”或“不适用”，不能静默删除。
- 因上下文或执行时限中断时，把已完成项、未完成项、失败命令和下一步写入计划，便于恢复；不得以“全部完成”掩盖中断。

## 三、必须保持的工程约束

- 保留 E2EE：不要把聊天正文、附件明文或解密密钥交给业务 API、推送桥接或供应商；诊断日志不得泄露令牌和密钥。
- 金额使用 Decimal/数据库定点类型；保持平衡分录、不可变历史账本、审计记录、账户并发保护和业务幂等性。退款/补偿通过新分录，不直接改写历史余额。
- HTTP 请求幂等、业务执行唯一性、外部托管订单唯一性分别建模，不能用前端防抖代替服务端幂等。
- 同库事务共享明确的 session；远程托管调用通过可恢复的状态机协调，不持有数据库锁无限等待网络。
- 不擅自变更手续费、确认阈值、审批规则、最小充值额或资产网络。若文案与规则冲突，核对现有产品配置；把有效规则统一给客户端展示。
- 优先局部、可审查修复。不要顺带大规模格式化、升级全部依赖、改名或重写整个 APP。
- 数据结构变更使用增量迁移，考虑已有数据与旧版客户端兼容。不能删除数据库重建，也不能改写已发布迁移来规避升级问题。
- 缓存治理区分可重新下载内容与用户唯一文件；不得以清空全部聊天历史、账户数据或关闭 E2EE 解决性能问题。
- 不删除测试、降低断言、吞掉异常、伪造成功响应或把未完成接口改成空返回来让测试变绿。

## 四、修复顺序

1. **资金和账号隔离：**F01–F06、A04、U04。
2. **推送和后台任务：**P01–P03、C02–C05。
3. **现有功能闭环：**A01–A03、U01–U03。
4. **容量和媒体可靠性：**C01、F07、M01–M04。

可以根据真实依赖调整先后，并在计划中说明。每个批次保持可审查边界，但全部属于本任务；完成第一批不是整体完成。

## 五、27 项修复清单

下列是审计基线的发现和验收方向。先用当前工作区核实，行号变化不构成跳过理由。若同时提供完整审计报告，结合其中固定提交链接读取上下文。

### F01 · P1 · 红包、转账创建及转账退款缺少统一事务

定位：`services/business-api/app/modules/redpacket/service.py`、`services/business-api/app/modules/transfer/service.py`、`services/business-api/app/modules/ledger/service.py`。

审计观察：红包和转账先调用不带 session 的 ledger.post，账本自行提交，再用另一个事务写业务单据。转账拒收、过期退款还把本金与手续费分成两次独立记账，最后才提交业务状态。

修复目标：同一数据库内让业务单据、账本、状态与 outbox 使用同一 session/事务；本金与手续费在一次平衡分录内完成退款。转账 accept 已传 session，可复用其事务边界；保留唯一约束和账户锁。

最低验收：在记账后、业务插入前、手续费入账前分别注入异常；断言整体回滚。并发同业务键只产生一个业务单据及一组分录，重试返回相同业务 ID。

### F02 · P1 · 同一已审批调账单可因并发或崩溃重复执行

定位：`services/business-api/app/modules/ledger/adjustments.py`。

审计观察：execute 在普通查询中检查审批状态，结束查询后用调用方传入的幂等键执行调账，再开启新事务标记 EXECUTED；没有以调账单 ID 固定执行幂等性，也没有跨整个过程锁定状态。

修复目标：执行键由服务端从 adjustment_request_id 派生；在锁定审批单或条件更新成功后，于同一事务执行账本与终态变更。相同审批单的业务执行唯一约束独立于 HTTP 请求键。

最低验收：同审批单、两个不同 HTTP 幂等键并发执行，只允许一笔账本交易；在记账与状态更新之间注入崩溃后重试仍只记一次。

### F03 · P1 · 充值事件去重会阻断补记账和确认数推进

定位：`services/business-api/app/modules/wallet/service.py`、`services/business-api/app/modules/wallet/models.py`。

审计观察：充值记录先独立提交，随后记账，再标记 CREDITED。收到已存在 event_id 时直接返回现有状态；没有继续完成未入账流程。首次 PENDING 的相同事件也不会更新确认数；换事件 ID 但保留同一 txid 又受 txid 唯一约束影响。

修复目标：事件接收记录与充值业务实体分离；按链上稳定身份聚合确认状态，状态仅单向推进；余额入账与 CREDITED 同事务，或用可重试的持久化任务补记账。链上多输出场景需定义完整唯一键。

最低验收：覆盖低确认→足够确认、同事件重放、新事件同链上交易、入账前后崩溃、乱序回调；最终只入账一次且中间失败可恢复。

### F04 · P1 · 提现订单号在数据库、账本和回调中的唯一范围不一致

定位：`services/business-api/app/modules/wallet/models.py`、`services/business-api/app/modules/wallet/service.py`。

审计观察：Withdrawal 按 user_id + client_order_id 唯一；扣款却在全局 wallet.withdrawal scope 使用 withdraw:{client_order_id}。WalletLedger 遇到同键直接返回，未核验分录内容；提现回调仅按 client_order_id 查找订单。

修复目标：以服务端全局唯一 Withdrawal.id 作为托管订单号及账本执行键；客户端键仅用于该用户的请求去重。重复键必须核验金额、地址、用户等规范化载荷；回调必须定位唯一订单。

最低验收：两个用户使用相同客户端订单号，仍各自对应唯一订单和正确分录；同用户同键不同金额/地址返回冲突；回调不能更新另一用户订单。

### F05 · P1 · 提现明确失败后缺少余额补偿闭环

定位：`services/business-api/app/modules/wallet/service.py`。

审计观察：submit_to_custody 先扣账后调用托管方；handle_withdrawal_webhook 与 resolve_unknown_withdrawal 在确认 FAILED 时仅更新状态，没有对应的退款分录。

修复目标：建立明确的 REQUESTED/提交中/已受理/未知/成功/失败已补偿状态机；可证实的最终失败使用业务订单 ID 派生补偿键，并与状态变更同事务。未知状态先查询托管结果再裁决。

最低验收：最终失败恢复一次余额；重复失败回调不重复退款；响应丢失但实际成功不能退款；人工与自动对账同时处理仍保持资金守恒。

### F06 · P1 · 群红包查看和领取缺少房间成员授权

定位：`services/business-api/app/api/redpacket.py`、`services/business-api/app/modules/redpacket/service.py`。

审计观察：入口验证登录身份；服务层对专属红包检查 recipient_id，但普通群红包只有 room_id、没有 recipient_id 时，detail/claim 没有验证当前用户是否属于该房间。

修复目标：在查看、领取等业务动作中执行权威房间成员检查，并定义退群后的领取策略；不要信任客户端自报成员身份，不要为授权检查把 E2EE 消息正文交给业务服务。

最低验收：成员、非成员、退群成员、被踢用户、专属接收人逐项验证；未经授权请求不得新增领取记录或账本分录。

### F07 · P2 · 钱包历史全量查询，分页接口未真正分页

定位：`services/business-api/app/modules/wallet/service.py`、`services/business-api/app/api/wallet.py`。

审计观察：充值和提现分别 .all() 拉取该用户全部记录，在 Python 中合并排序；响应 next_cursor 固定为 null。

修复目标：设置服务端最大页长，按 created_at + id 做稳定游标分页；在数据库完成有界检索，检查 user_id/时间/ID 组合索引。

最低验收：大历史数据集下每页数量受限；翻页无重复遗漏；查询执行计划和峰值内存不随总历史量线性扩张。

### A01 · P1 · 客户端获取充值地址的接口在当前钱包路由缺失

定位：`apps/mobile_flutter/lib/core/business_api_client.dart`、`apps/mobile_flutter/lib/features/wallet/wallet_page.dart`、`services/business-api/app/api/wallet.py`。

审计观察：客户端 walletDepositAddress 请求 /wallet/deposit-address，钱包页面提供获取入口；当前 create_wallet_router 没有对应路由。

修复目标：补全经认证的地址获取/分配接口、地址归属持久化、资产网络校验及错误契约；未完成真实托管接入时用功能开关关闭充值入口并准确提示。

最低验收：从真实客户端调用注册后的 API，验证首次分配、重复获取、跨用户隔离、托管失败及返回结构；测试必须跨路由与服务，不能只测客户端拼接字符串。

### A02 · P1 · 提现回调处理函数未接入公开回调路由

定位：`services/business-api/app/api/wallet.py`、`services/business-api/app/modules/wallet/service.py`。

审计观察：/wallet/webhooks/custody 无条件调用 handle_deposit_webhook；该函数拒绝非 DEPOSIT_CONFIRMED 事件。虽然存在 handle_withdrawal_webhook，但这条公开路由没有分发给它。

修复目标：统一验证签名和请求结构后，按白名单事件类型分发；为不支持事件返回稳定错误；结合 F04/F05 处理唯一订单、重复和乱序状态。

最低验收：以有效提现事件实际请求该 HTTP 路由，验证状态推进；无效签名、未知类型、重复事件和乱序事件均有确定结果。

### A03 · P2 · 鉴权刷新与重试缺少完整超时边界

定位：`apps/mobile_flutter/lib/core/business_api_client.dart`。

审计观察：_authorized 对首次操作设置 timeout；遇到 401 后的 refreshSession 和第二次 operation 没有相同边界。刷新直接 client.post；退出登录也等待没有该超时保护的请求后才清理会话。

修复目标：对整次授权操作设置总截止时间，覆盖初次请求、刷新与重试；支持取消，退出登录的本地清理有确定完成时限。涉及资金的重试保留原业务幂等键。

最低验收：分别挂起初次请求、刷新、刷新后重试、退出请求，均在规定时间返回可识别状态；取消后不能用迟到结果恢复已退出会话。

### A04 · P1 · 钱包仍固定接沙箱，生产配置缺少钱包密钥门禁

定位：`services/business-api/app/api/wallet.py`、`services/business-api/app/integrations/custody/sandbox.py`、`services/business-worker/app/main.py`、`services/business-api/app/core/config.py`。

审计观察：API 与 worker 直接构造 SandboxCustodyProvider；其订单状态存在进程内字典，生成的是沙箱地址/交易结果。钱包签名密钥为空时回退开发默认值，而 production 必填密钥验证清单没有包含 wallet_webhook_secret。

修复目标：明确 sandbox/production 模式，生产启用资金功能时拒绝沙箱 provider 和缺失/开发密钥；通过统一工厂注入真实托管实现，持久化外部订单状态，落实对账、密钥轮换和环境隔离。

最低验收：生产模式缺失钱包密钥或使用沙箱必须启动失败/关闭资金能力；API 与 worker 对同订单结果一致，重启可恢复；真实托管在隔离环境完成端到端验收。

### P01 · P1 · 推送临时失败仍返回 HTTP 200，丢失协议重试机会

定位：`services/getui-bridge/app/main.py`。

审计观察：网络、超时、临时业务错误均只累加 transient_failures；函数最终仍返回 200。该变量没有参与结果判断。源码注释认为“200 空回让 Synapse 重试”，与协议的错误重试语义不一致。

修复目标：临时失败返回可重试错误，或先可靠入队再成功应答；部分成功场景对重试做通知去重。仅永久无效设备进入 rejected；成功返回完整协议结构。

最低验收：供应商超时/5xx 后，端到端验证 homeserver 重试并最终到达；部分设备成功时无重复提醒；临时故障不能删除有效 pusher。

### P02 · P1 · 个推 HTTP 401 的令牌刷新分支不可达

定位：`services/getui-bridge/app/getui_client.py`。

审计观察：非 200 响应解析出业务错误码后直接抛出 GetuiPushError；后面的 code == 10001 刷新重试逻辑因此无法处理 HTTP 401 + code 10001。

修复目标：统一解析 HTTP 状态和业务码；确认令牌失效后清缓存并仅刷新重试一次，复用该通知的请求身份。鉴权错误不得误判为 CID 永久失效。

最低验收：模拟 401/10001→刷新成功→推送成功，确认刷新一次；再次 401 不无限循环；并发刷新应合并以免刷新风暴。

### P03 · P1 · event_id_only 推送格式无法保证当前来电分类逻辑成立

定位：`apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart`、`services/getui-bridge/app/notify.py`。

审计观察：客户端注册 event_id_only；桥接仅在 notification.type 以 m.call 开头时归类 call，其余均为 message。协议不保证该格式带 type；加密事件类型本身也不能直接表达内部来电信令。

修复目标：保持最小化推送与 E2EE，采用设备唤醒后同步、由客户端解密并确认有效来电的链路；需要辅助标识时必须专门设计可信度、隐私和时效性，不能靠向推送厂商发送明文消息修补。

最低验收：对省略 type、加密事件、陈旧来电、已取消来电及重复通知验证分类和同步；不能伪造 callId，也不能自动接听。

### C01 · P1 · 异步入口直接执行同步网络、数据库和密码计算

定位：`services/business-api/app/api/identity.py`、`services/business-api/app/modules/identity/passwords.py`、`services/getui-bridge/app/main.py`。

审计观察：登录 async 路由内直接进行同步数据库访问和 Argon2 校验；推送 async 路由调用同步 httpx.Client，并按 CID 串行发送。密码哈希配置本身较重，不应在事件循环直接计算。

修复目标：同步工作使用框架线程池入口或显式受限卸载；或统一使用异步驱动。密码计算设置受限执行容量，供应商请求使用连接池和有界并发。不要为提升速度降低密码哈希安全强度。

最低验收：用慢供应商和并发登录负载验证无关轻量接口仍及时响应；记录 p95/p99、事件循环延迟、线程池排队、RSS 和连接池等待。

### C02 · P1 · Outbox 发布主题与 worker 处理器不完整匹配

定位：`services/business-worker/app/main.py`、`services/business-worker/app/worker.py`、`services/business-api/app/core/outbox.py`、`services/business-api/app/modules/ledger/service.py`。

审计观察：当前 worker 仅注册 identity.email / identity.matrix / identity.profile；claim_batch 不按处理器主题筛选，而账本会发布 ledger 等其他主题。找不到 handler 时失败并固定延迟重试；未见该路径的最大尝试次数或死信终止。

修复目标：列出生产者→主题→消费者契约，补齐处理器或划分明确消费者；对不可处理主题告警并进入可审计死信流程，采用有界退避与人工重放。不要简单标记成功来隐藏积压。

最低验收：枚举所有 enqueue 主题，与部署消费者覆盖一致；未知主题不无限占用热队列；ledger 事件在目标处理器完成后才成功，重复投递的副作用幂等。

### C03 · P1 · 维护任务异常会中断整个队列 worker

定位：`services/business-worker/app/worker.py`、`services/business-worker/app/main.py`。

审计观察：每次 run_once 先顺序执行维护任务，位于消息处理 try/except 外；run_forever 没有隔离该异常。红包/转账过期、钱包维护或朋友圈维护任一任务抛错，都可能在领取消息前退出循环。

修复目标：给独立维护任务单独异常边界、调度周期和健康状态；关键任务可拆独立 worker。避免每个队列批次都先运行全部维护，保留失败告警，不能静默吞掉异常。

最低验收：注入钱包维护异常时其他主题仍可领取和处理；失败任务可重试且暴露告警，健康检查能区分“进程活着”与“任务持续失败”。

### C04 · P2 · 推送注册与退出注销存在异步竞态

定位：`apps/mobile_flutter/lib/features/push/matrix_pusher_service.dart`、`apps/mobile_flutter/lib/app_home.dart`。

审计观察：ensureRegistered 只防止重复注册；unregister/dispose 没有等待或使在途 gateway.create 失效。注销删除先完成、迟到注册后完成时，可重新写入旧 pusher；注册失败的迟到回调也能再次安排重试。

修复目标：将推送绑定归属到会话，使用 generation/disposed 标记和串行生命周期；注销等待在途注册结束并补偿删除，迟到回调不能重新排队。

最低验收：用可控 Future 固定 create→logout/delete→create完成的顺序，最终无旧账号 pusher；dispose 后失败回调也不能启动重试。

### C05 · P2 · 前台服务启动失败时仍申请唤醒锁，stop 提前返回

定位：`apps/mobile_flutter/lib/core/notification/sync_keepalive_service.dart`、`apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt`。

审计观察：ensureStarted 在 backend.start 失败后仍调用 hooks.acquire；_running 保持 false。stop 以 !_running 提前返回，因此不取消已建 watchdog，也不 release；原生锁的 acquire 未设置超时。

修复目标：资源清理不能依赖“服务已启动”一个布尔值；分别跟踪已持有资源，在失败和 stop 的 finally 中幂等释放，取消在途启动，选择合理锁超时。

最低验收：模拟 start 抛错后 stop，断言 timer、CPU/Wi-Fi lock 均释放；反复前后台/退出、start与stop交错后资源计数归零。

### M01 · P1 · 普通文件发送全量读入内存，缺少该入口的预检限制

定位：`apps/mobile_flutter/lib/features/matrix/room_page.dart`、`apps/mobile_flutter/lib/features/matrix/media_message_service.dart`。

审计观察：会话普通文件入口调用 sendFile，选中后直接 readAsBytes 再 sendEncryptedMedia，没有先检查文件长度。这条路径不经过另一套附件上传控制器的限制。外围 timeout 也不会自动取消内部读文件或发送。

修复目标：在读取前统一做大小/类型/可读性检查，集中所有附件入口；按 SDK 能力使用文件或有界分块加密上传，设置并发、内存预算及真正取消。失败重试保留同一消息事务标识。

最低验收：超限文件在 readAsBytes 前被拒绝；低内存设备测试边界文件和多个并发任务；取消/超时后无迟到发送或重复消息。

### M02 · P2 · 语音下载完成后未检查是否仍是当前播放任务

定位：`apps/mobile_flutter/lib/features/matrix/voice_playback_controller.dart`。

审计观察：_start 先切换 playingIds，等待附件后无条件 engine.play；stopAll/dispose 没有使在途加载失效。

修复目标：为每次播放分配 generation；每个 await 后检查 generation、会话与 disposed 状态；stop/dispose 同时使在途任务失效，严格定义引擎归属。

最低验收：可控延迟下完成 B 再完成 A，最后只能播放 B；stop/dispose 后完成下载不能调用 play 或 notifyListeners。

### M03 · P2 · 媒体缓存直接写最终文件，损坏文件会被当作命中

定位：`apps/mobile_flutter/lib/features/matrix/media_cache.dart`。

审计观察：store 直接写最终路径；cached 仅检查 exists。应用退出、磁盘满或并发读取发生在写入期间，会留下半文件或读到未写完内容；读取路径没有完整性验证和损坏后重下载闭环。

修复目标：同目录唯一临时文件写完并校验后原子替换；按媒体键合并写入；记录长度/完整性元数据，检测损坏后删除可再获取缓存并重试，不要删除唯一的原始文件。

最低验收：注入半写入、磁盘满、写时读取与进程中止；重启后只能读到完整文件或缓存未命中，损坏项能恢复。

### M04 · P2 · 媒体缓存按条数而非字节限额，磁盘缓存无容量治理

定位：`apps/mobile_flutter/lib/features/matrix/media_cache.dart`。

审计观察：内存 LRU 默认 48 条，视频缓存 3 条，保存完整解密字节；没有总字节预算。磁盘 chat-media 仅追加，不做自动容量治理。

修复目标：采用按字节加权 LRU，大视频优先磁盘文件播放、避免常驻完整 Uint8List；设置磁盘软/硬配额、用户可见用量和可再下载缓存清理策略，按账号归属管理。

最低验收：大视频连续切换时实测 RSS 达到稳定上限；缓存超额后按策略回收；离线唯一文件/用户主动保留附件不被误删。

### U01 · P1 · 提现按钮未绑定提交状态，每次点击产生新订单身份

定位：`apps/mobile_flutter/lib/features/wallet/wallet_page.dart`、`apps/mobile_flutter/lib/ui/components/modern_action_button.dart`。

审计观察：withdraw 没有提交中互斥，每次点击以当前毫秒时间生成 clientOrderId。通用按钮只有外部传入 loading 时才禁用，该处没有绑定提交中的 loading。

修复目标：一次明确提现意图生成并持久化一个随机订单键；提交中禁用并显示状态，超时先查该订单后重试。服务端仍执行 F04 的全链路幂等，按钮防抖不能代替它。

最低验收：快速双击只创建一单；响应丢失后重试返回原单；用户明确发起第二笔时才创建新业务键。

### U02 · P2 · 提现页面轮询和异步状态更新缺少生命周期保护

定位：`apps/mobile_flutter/lib/features/wallet/wallet_page.dart`。

审计观察：提交 await 后的 setState 及 catch 内 setState 无 mounted 检查；新 Timer.periodic 覆盖 poller 前未取消旧定时器，回调共享可变化的 withdrawalId，异步轮询无串行限制且异常未捕获。

修复目标：由独立订单控制器持有单一可取消轮询，捕获固定订单 ID；完成一轮后再调度下一轮；所有 UI 更新检查归属与 mounted，退出取消全部资源。

最低验收：提交后立刻退出不报错；多单切换无旧任务污染；请求慢于 10 秒也不会并发堆积；轮询异常转为明确可恢复状态。

### U03 · P3 · 充值确认数文案与后端默认规则不一致

定位：`apps/mobile_flutter/lib/features/wallet/wallet_page.dart`、`services/business-api/app/modules/wallet/service.py`、`services/business-api/app/api/wallet.py`。

审计观察：钱包 UI 写“20个确认后到账”；WalletService 默认 confirmation_threshold=12，当前路由创建时没有覆盖该值。

修复目标：由钱包能力/配置接口返回有效网络、最小金额、确认阈值和预计状态，客户端统一展示；测试环境与生产环境的规则要可识别。

最低验收：改变服务端阈值后 UI 同步呈现，并用阈值前一刻/达到阈值的事件验证业务行为。

### U04 · P1 · 朋友圈缓存没有按账号隔离，切换账号可展示前账号内容

定位：`apps/mobile_flutter/lib/core/cache/cache_repository.dart`、`apps/mobile_flutter/lib/features/moments/moments_page.dart`、`apps/mobile_flutter/lib/core/session_bootstrap_controller.dart`、`apps/mobile_flutter/lib/core/business_api_client.dart`。

审计观察：朋友圈使用进程单例及固定持久化键 cache.moments.feed.latest；页面优先返回该缓存再刷新。当前退出链路清理业务会话并暂停 Matrix，没有清除此朋友圈缓存或按用户切换命名空间。

修复目标：缓存键纳入稳定账号 ID 与服务端身份；账号切换立即清空当前展示并切换仓库，迟到 A 请求不能写入 B 缓存。只处理对应账号缓存，不应全量删除 Matrix 聊天历史。

最低验收：A/B 使用不同可见内容，在线和离线切换后 B 从首帧起均不能看到 A feed；A 的迟到刷新也不能覆盖 B。

## 六、容易修偏的地方，必须额外处理

### 资金状态、迁移与外部依赖

F01/F02 不只是在函数上加锁：检查业务单据、账本、状态、审计及 outbox 是否真的在同一提交边界。调整 Ledger API 时核对全部调用方，避免只修一个入口造成另一入口失效。

F03/F04/F05 需要一起设计充值/提现的稳定身份、终态和恢复路径。旧 client_order_id 迁移为内部全局订单身份时，保留既有已提交订单与供应商回调的映射；不要重新生成外部订单导致重复出款。对状态 UNKNOWN 的订单先确认外部结果，不能见到超时就退款。

A04 不要求你凭空接入一个未提供的真实托管商。如果当前只有沙箱：实现明确的 provider 抽象、配置校验、能力开关和生产拒绝错误接线的门禁；完成能够验证的状态机、接口和持久化修复；列出真实 provider 接入缺少的具体契约/配置，继续其他任务。**沙箱成功不能标为真实充值提现已完成。**没有提供真实 provider 的，不要自行选择厂商。

如果新约束发现已有重复/冲突数据，先提供只读检查和迁移处理策略。不能自动删订单或改历史账；不要将未经核实的数据修复脚本作为生产可直接执行的结论。

### 个推重试、去重与来电

P01 修复不能只把 200 改为 503：同时检查限频器是否已经在失败前消耗资格，避免立即重试被静默跳过后再次被确认成功。明确部分设备成功、部分失败的处理方式，避免成功设备重复提醒；保留仅永久失效 CID 才进入 rejected 的语义。可使用内部最小化事件去重标识，但不要把消息明文发给供应商。

P02 对照个推真实协议处理 HTTP 状态和业务码，补齐 401/10001 的一次刷新重试以及多请求刷新竞争；不能无限重试，也不能把鉴权失败当成设备失效。

P03 不能靠给 event_id_only 的测试负载硬塞 type 来“修复”。验证设备唤醒、同步、解密、识别有效来电到通知/UI 的真实调用链；处理过期和取消来电。不能虚构 callId、自动接听，也不能承诺绕过操作系统限制实现所有状态强制弹出。

厂商 ROM、通知权限、后台限制、全屏通知能力是待我真机验证的条件。可以提供能力检查和清晰引导，但不要一进入 APP 就无差别申请所有权限，或反复弹窗逼用户授权。

### 生命周期、媒体和缓存

C04/C05/M02/U02 不能只补 mounted：服务端 pusher、副作用、引擎播放、定时器和锁都要有归属、失效与清理机制。销毁后不更新 UI 不等于后台任务已经停止。

M01 检查所有附件入口和实际 SDK 能力。若 SDK 只能接收完整字节，不伪造流式加密接口；先落实读取前上限、并发预算和取消语义，并准确记录 SDK 限制。

M03 的临时写入与原子替换需与目标平台文件系统行为相容；M04 采用明确字节预算，同时控制在途任务，不能只限制完成缓存。缓存按账号/服务器划分，退出清理不能误删用户唯一媒体。

当前已有视频转码优化，保留选择更小输出及原始文件回退。额外核对异步取消是否可能取消下一次压缩；只有在当前插件语义或受控测试支持时修复，不把未经验证的猜测写成确定根因。不承诺所有视频固定压缩比例。

## 七、验证要求

对资金、授权、推送协议和异步竞态增加能证明行为的回归测试。优先先复现失败，再实现修复；已有测试能覆盖时复用。文案等低影响调整不需要堆砌形式化测试。

1. **数据库正确性：**采用隔离 PostgreSQL 和不同 session/连接验证真实事务与并发；覆盖同业务不同 HTTP 键、不同用户同客户端键、提交中崩溃、退款重放、回调乱序。SQLite 或内存伪实现不能替代这些结论。
2. **HTTP 契约：**从注册后的路由实际发起测试，覆盖充值地址、提现回调、错误签名、对象授权及响应格式；不得只调用 service helper 就宣布接口已接通。
3. **推送与 worker：**覆盖供应商临时失败、401 刷新、部分设备成功、限频和重试交互、所有生产主题的消费者归属、维护任务失败隔离。
4. **Flutter 时序：**用可控 Future/时钟固定 A 慢 B 快、注册中退出、页面销毁后完成、轮询重叠、提现重复点击；断言迟到任务没有实际副作用。不要靠随机 sleep 或字符串匹配判定修复。
5. **媒体：**验证读取前大小限制、取消后无迟到发送、缓存半写入恢复和字节预算。真机内存、画质、ROM 推送和像素布局留给我测试。
6. **回归与构建：**运行受影响模块的现有测试、静态检查及当前工具链可执行的构建；根据具体剩余风险扩展，不重复无目的的大范围检查。

运行前查清工具链和依赖，不虚构命令。若测试依赖缺失，优先使用项目已有隔离环境/锁定依赖安装方式。无法取得资源时记录原始错误、已尝试的合理替代、未验证的结论，继续其他可执行工作；不能将“环境缺失”变成跳过全部测试的理由。

不要声称压力容量已达某个 QPS、真机不卡顿或后台必达，除非有对应真实证据。本次无需以真机测试通过作为代码交付前置条件。

## 八、最终交付

完成当前可执行修复后，检查完整 diff、工作区状态和测试结果，更新计划，并生成：

1. `docs/reports/chatflow-audit-remediation-result.md`：27 项逐项结果，包含改动文件/关键符号、根因、验证命令和真实结果、剩余风险。状态使用“已修复并验证 / 代码已修复但验证受限 / 当前代码已满足并有证据 / 不适用并有反证 / 外部阻塞 / 未完成”，不要合并为一个模糊的“完成”。
2. `docs/testing/chatflow-manual-acceptance.md`：供我执行的简洁真机清单，写清操作、预期结果、失败时需记录的信息；包括消息/来电后台、图库视频、附件缓存、语音切换、权限拒绝、账号切换和钱包重复提交。
3. 若有数据库或配置变更，在现有文档或上述结果中写明增量迁移、旧数据/旧客户端兼容、必需配置及回退限制；准备好可审查内容，不自动执行生产变更。

每项“已修复并验证”必须有实际代码或现有实现证据，以及足以覆盖该项风险的行为验证。仅门禁已完成但真实托管未接入时，分别记录，不标为资金端到端完成。

最后向我简洁汇报：修复了什么、实际验证了什么、还有哪些具体阻塞、哪些需要我真机验证。不要虚构 commit SHA、GitHub 上传、部署结果或测试数量。保留完整可审查的工作区改动，便于我之后同步 GitHub 交给审查。

**现在开始核对当前工作区并执行修复，持续推进所有可执行批次，不要只返回一份计划。**
