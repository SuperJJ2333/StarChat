# 冷启动发送阻塞与本人气泡方向：源码修复

## 恢复入口

- 用户：2026-10-27要求讨论解决；确认Android和iOS均为发送按钮不可点，本人消息先左后右。设备当前具体build尚未独立读取。
- 范围：用户已明确批准四条行为要求，实施共享 Flutter 源码和测试；不打包、不发布。
- 基线：maintenance-completion/StarChat，codex/android2235-release-20261025，6853790df944fa60543dba93164ab9128d17ad94。Android2235实际编译源码52bbd8c5。原主树既有改动保留。
- 所有权：本任务计划/记录，以及 app_home.dart、room_page.dart、matrix_e2ee_client.dart 和对应回归测试。当前分支 codex/cold-room-send-identity-20261027，复用候选工作树。
- 已读移动交付流程、current-state、移动AGENTS及产品规格。主树CodeGraph先查询；主树图有漂移且并非2235交付树，候选无.codegraph，因此本结论来自候选当前源码读取，不冒充动态图/真机证据。
- 计划：[实现计划](../../superpowers/plans/2026-10-27-cold-room-send-identity.md)。下一步：读取完整回归与规格审查结果，修复发现项，再质量/安全审查。

## 源码证据

1. `room_page.dart:6890` 的发送回调在 `controller == null || !_queueReady` 时为null；`_send:2385`同样短路。`_load:1712`等待openLogicalRoomTimeline后才创建controller；pendingOutbox回调到1756之后才接入。无缓存或慢本地时间线时，历史读取直接阻塞发送入口。
2. `app_home_interactive_local_test.dart:211–233`人为挂起时间线，明确断言发送按钮为空、键盘发送不入队。这是现有受测行为，不符合用户现在明确的体验要求。
3. 已显示缓存的分支另有Outbox就绪闸门：`app_home.dart:682–709`等待持久化store query；页面 `_queueReady:1089`等待manager接入。Outbox与Matrix历史都使用FFI SQLite worker，但本轮未测出设备上具体慢在哪里，不能把所有等待直接归因网络下载或全量历史。
4. SDK `client.dart:1940–1970`明确：seedStartupRooms只创建显示对象，不填凭据/userID。上层 `MatrixSdkE2eeClient.userId:9873`可从已获准的startupAdmission读取账号；roomInfo:2041采用该身份。
5. 同一时间线 `_message:4329`却用 `event.senderId == _lease._activeRoom.client.userID`计算isOwn。SDK userID尚为空时，本人缓存被归为非本人。`_cachedMessage:3660`的复用条件不包含显示身份；待恢复事件替换/刷新才重新投影，可以解释左→右。该路径为源码确认，设备实测仍待补充。
6. `cached_room_local_ready_test.dart:21`固定返回userID，无法覆盖真实的“admission已知、SDK userID为空”窗口。已有本地新发/outbox回显均显式isOwn=true，因此本现象更符合缓存历史本人消息投影错误，而非服务端修改发送者。

## 建议方案与验收

在既有Outbox及租约机制上，独立处理身份就绪、持久化入队就绪、网络派发就绪、历史显示就绪。历史读取/补载不能作为文字入队的前置条件。账号和目标明确、允许本地入队且持久化成功后显示右侧待发送气泡；业务授权、成员/发送权限、加密和网络就绪后沿原txid实际派发。落盘失败保留输入并明确错误，不用易丢失的纯内存队列伪装成功。

气泡归属采用当前有效租约/账号范围内已确认的显示身份，在首帧与SDK接管后保持一致；不依赖昵称/头像/成员列表加载，不将显示身份作为鉴权或加密就绪证明。账号切换/租约退役必须取消旧异步结果。

| ID | 验收 |
| --- | --- |
| C1 | 挂住历史读取/解密/补载，Outbox已就绪时可点击发送并可靠落盘 |
| C2 | SDK userID为空而当前admission已确认时，本人缓存首帧即右侧、他人左侧 |
| C3 | SDK接管/历史替换后方向和消息稳定ID不变，不重复、不跨时间窗口跳跃 |
| C4 | Outbox慢/失败、离线、快速退房与账号切换：不丢正文、不跨账号、不重复派发 |
| C5 | 权限拒绝/加密未就绪仍阻断实际网络派发，历史失败不拖垮独立发送队列 |

不以加超时、全局提前置ready、强设所有isOwn或取消鉴权作为修复。既有排序/窗口修复保留，本次处理的是发送入口和身份投影。

## 阶段与状态

2026-10-27（UTC+08:00）完成只读源码调查和讨论方案；精确开始/结束时间未记录，不编造耗时。尚无新red/green、完整门禁或两端真机通过证据。无本任务CI/隧道/后台命令。现有Android2235及iOS发布身份未改变。

### 用户批准后的实施记录（覆盖上面的调查阶段状态）

- 用户明确要求并授权：独立文字入队、持久化后右侧气泡、稳定已确认身份、失败保留输入；不取消原权限/加密闸门。
- Ruling: 历史控制器尚不存在时只投影本页已成功写入的 outbox 行；已有账号调度器负责发送，历史控制器恢复后按原 txid 接管。避免引入另一套持久化队列。
- Ruling: 检查发现后台租约工厂也依赖 openRoomTimeline，纳入同一修复。新增租约文字方法复用 _withLeaseSend、sendTextEvent、既有异常分类与计时；不改加密/权限算法。
- Ruling: 严格持久化就绪条件仅用于文字提交；原媒体路径继续使用自身持久化服务。相邻测试发现早期将文字队列条件套到媒体准入导致相机回归，已撤回该扩大影响并单项复验通过。
- 证据根：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-27/cold-room-send-identity/。
- 15:40:32–15:40:47 red：历史阻塞和空 SDK 身份归属失败符合预期；15:41:58–15:42:03 red-admission；15:43:27–15:43:33 green-first exit0。
- 15:48:18–15:48:24 red-background：历史不可用时后台未发送；15:48:46–15:48:52 green-background exit0（含权限及相机回归）。
- 15:49:40–15:49:45 red-retry-tx：失败重试生成新 txid；15:50:26–15:50:32 green-retry-guards exit0。持久化失败及重复提交沿原 txid，写入期间新编辑保留。
- 15:51:30–15:51:44 首次全量预检仅 lint 失败（未用 import 和测试花括号），修正后重新运行；原记录保留 lint-attempt-*。
- 15:54:43–15:54:47 scripts/verify.ps1：独立 Python 3.12 预检 PASS，随后缺少候选 .env 而停止（exit1）；未复制生产配置。移动边界与 UI/仓库策略单独执行中。
- 当前完整 Flutter 和规格审查运行中，不能提前宣称全量通过；无新安装包、无真机结果。

### 审查修正与最终门禁

- 独立规格审查 cold_send_spec：5 项（引用/@、ACK 删除竞争、光标/引用编辑、发送意图时机、历史重试入口）均建立失败测试后修复。red-review-metadata-ack 3 FAIL；red-review-composer-valid 2 FAIL；red-review-races 3 FAIL，后续 green-review-races 全部通过。
- 独立质量/安全审查 cold_send_quality：要求 ACK 同步捕获且 sent 单调不回退，并恢复误删的拍一拍发送意图；与多余的重复意图调用一并纠正。red-quality-ack-nudge 为 3 FAIL；green-quality-ack-nudge 为 37 PASS/0 FAIL（包含超过 512 条其他 ACK 的缓存淘汰及迟到旧读取）。审查后修复由根代理按红绿测试及完整门禁验证，不冒称独立复审通过。
- 原 first-full 为 6406 PASS/9 诊断 SKIP/6 FAIL：1 项既有铃声真实时间竞争、1 项测试 fixture 未绑定账号、其余 4 项为前一 widget 失败后清理级联。已保留失败日志；仅将铃声测试改为受控测试时钟、fixture 改为当前账号，不改通话运行代码。
- 质量审查发现未修项时中止了中间全量，保留 quality-interrupted-*；中断后的 V: 映射核对确属本任务、确认测试子进程结束后才删除。之后重新冻结全部输入运行最终全量。
- final-focused 为 111 PASS/0 FAIL；最终 ACK/拍一拍增量为 37 PASS/0 FAIL；完整结果与最终 SHA 待填入验收报告。
- Ruling: 本地 outbox 增加 text_metadata 是保留原有文字语义所必需，使用可空加列而非替换表。未来安装后若回退旧二进制，其 schema v2 打开器不支持直接读取 v3；发布前须保留兼容读取逻辑或受控恢复数据，不能通过删除数据库回退。本轮未安装，用户设备数据未迁移。
- Ruling: 质量发现的重复意图调用与拍一拍误删来自同一处编辑偏移，作为一个行为恢复修正，不扩展拍一拍业务功能。
- 待交付：完整 Flutter 最终结果、诊断开启变体、最终移动边界证据汇总；候选分支本地提交；后续 Android/iOS 真机验证仍待打包授权。

### 交付状态

- 源码验收完成，结果见[验收报告](../../verification/2026-10-27-cold-room-send-identity.md)。最终运行源码 16 个 Dart 文件与完整运行输入一致（delivery-validation.json，mismatch=[]）。
- 最终全量 6421 PASS / 9 SKIP / 1 Windows 临时目录 errno32 清理失败，原 exit1 保留。原样单独复跑受影响完整文件 12 PASS；诊断变体 9 PASS / 1 默认分支 SKIP。默认分支在全量执行，九项诊断跳过在变体执行。
- Ruling: 按用户及交付流程“未变输入复用”规则复用其余成功用例；不再为同一源码重复整个套件，不把原全量记录改称绿。Windows 偶发目录占用仍是宿主测试环境限制；若复现需继续查外部句柄，不能跳过业务断言。
- 最终移动边界 mobile-delivery：404 PASS / 1 Ruby SKIP；UI34/540 PASS、仓库策略 PASS、格式16文件0改动、analyze0。总 verify 缺 .env 的阻断仍明确保留。
- 下一步：按“先交付源码和验证”保留候选分支；后续获打包请求后准备对应安装包，再由 Android/iOS 真机检验冷启动发送与历史恢复。本轮不自动发布，不改更新提醒。
