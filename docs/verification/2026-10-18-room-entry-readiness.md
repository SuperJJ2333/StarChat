# Android 0.4.59（2228）缓存房间准入与冷启动验收

2026-10-19 01:44+08检查点：产品d1/2228的共享门禁已完成，普通Debug已保数据安装。真实MAIN/LAUNCHER全房测试发现页面前等待已移除，但缓存覆盖仍未闭合；原生r3/r4各5/6成功、1处后续导航失败，不是全部通过。正在仅扩展诊断包的遮罩元数据，普通产品不变。

## 用户问题与已确认根因

旧的受管理入房路径共用AppHome：快照或房间显示头不可用时，代码在取得合法租约后仍先await PreparedRoomPageEntry.prepare，准备本地时间线完成才push页面。它能解释SDK已经就绪仍需等待。基线2225有13条有效trace，12条lease→push1865–3201ms、1条305ms；其中含调度与准备，不能称纯SQL时间。枚举最终校正为14个不同房间，原15次尝试含一个裁切行。

共享慢分支不等于相同拒绝原因：设备已分别观测businessRefreshPending与headUncommitted。2227普通包14房内容均被观察到，但只有4个roomHIT，内容324–419ms；10个MISS为1045–4498ms。其push15–49ms、lease→push3–28ms，说明移除页面前等待仍不足以证明缓存覆盖问题已闭合。这些是2227数据，不是2228性能结果。

## 2228实现

- 最小账号/安装/设备/指纹/数据库代次/密钥/注册设备/摘要/隐私/tombstone绑定仍在缓存展示前完成。合法已提交AEAD缓存可以先展示，完整身份与数据库检查、SDK恢复继续在后台执行；有效pending refresh只允许原有缓存只读展示，未提交或失效快照仍拒绝。
- 已取得合法租约后打开房间，canonical本地时间线在同一页面继续加载。有效缓存显示真实气泡并可滚动、持久排队；没有合法缓存时保留真实pending画布与草稿。完整身份、SDK、密钥、成员与业务权限继续约束实际发送。
- 后台每个新失效revision先准备top40房间×每房最多8个源事件，合法AEAD提交后再补至40。8是读取预算，过滤后可能更少或为空，coverage保留partial。已有同revision完整head不会被8条降级；深读失败且未撤销时保留浅层文件。账号、隐私、Room或generation变化照旧拒绝迟到结果。
- 旧的浅层显示读取先结束，新的repair只等首批提交或失败释放，不等深读完成。业务pending导致writer拒绝后，显示repair仍独立运行。每轮重新读取admission，prepare清理保留secure head当前引用的AEAD文件。
- 全局隐私失效、top/current/pinned/front优先级、头像元数据、隐藏/撤回过滤和原无数据库fallback保持。复制/多轮哈希移至UI isolate之外，保留完整检查语义；不宣称其墙钟已稳定缩短。

冻结源码d1ded931a043d894a5abe3b163fefc019729b83b。DOMAIN/SPEC后独立QUALITY/security实现审查PASS。关联[任务](../workflow/tasks/2026-10-18-room-entry-readiness.md)、[计划](../superpowers/plans/2026-10-18-room-entry-readiness.md)、[ADR](../adr/2026-10-18-room-entry-readiness.md)。本次无真实消息发送、无生产更新元数据写入。

## 2228验证证据

- 有效RED：独立HEAD967归档只注入新测试，深读被挂起时已提交head为null，2秒按预期失败。早期actual-main RED因fixture业务503不具writer资格而作废，保留记录。
- staged-scheduling10PASS：真实SQLCipher/AEAD浅层读回、深读/prepare失败保留文件、privacy/account撤销、Room/generation迟到、40不降级、新revision重建，以及pending writer与竞争display调度。源事件为合成普通Matrix事件；实际main另保留源E2EE证据。
- actual-main定向1PASS/48秒：完整预检、业务恢复或当前房间SQL被挂起仍可进入/滚动。8条显示触发正常历史分页，验证缓存子序列保序、ID唯一、同一页面与后续锚点，允许合法历史扩充。
- 最终冻结源码analyze0issues/41.8秒。平台边界23PASS/1deselected；原禁用字面量断言使用相同roots、Git跟踪文件枚举等价扫描PASS，6315个跟踪路径，不扫描生成的APK目录。版本契约3PASS。聚合verify.ps1缺.env，未执行，未导入生产凭据。
<!--2228_FULL_GATE-->
- 最终共享门禁d1：6271可见PASS / 9既有SKIP / 0FAIL，test/analyze/runner退出0，source_stable=true。2026-10-18 16:31:01.5080057→17:19:07.9120927UTC，约48分06秒，含offline pub/analyze；测试本身2723.271秒。证据final-shared-2228/receipt.json，实际Olm/SQLCipher DLL及pub锁哈希绑定。此前607的6261PASS为历史证据。
<!--2228_FULL_GATE_END-->

## 构建与实际安装

| 产物 | SHA256 | 字节 | 源码/目标 |
| --- | --- | --- | --- |
| 普通Debug | 8f568efa823bb51f917f8825173f662c06b78767b52e16875d52eeddc60ee607 | 126130522 | d1ded931 / lib/main.dart |
| 合成原生验收包 | fadf1d1678a29a8c92f082a0c858719ab011bf503b5df6b3aa83c05ca9422b36 | 127490394 | d1ded931 / android_startup_local_projection_test.dart |

两者均为standard/x86_64 Debug，仅供本模拟器；包名com.liuhetong.mobile.debug，版本0.4.59+2228，固定证书SHA75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。2145个mobile blobs在独立archive编译前后核对。源码构建→Apktool2.12.1重建→zipalign36-P16→固定签名→清单/DEX/资源/资产/native语义校验均PASS。

原生包构建16:29:58→16:42:50UTC，普通包16:43:32→16:53:41UTC。工具时段与全量并行，不能累加成总墙钟。主动分析未知时段不估算。普通包已用-r覆盖安装，设备APK字节与上表一致，UID10090、firstInstall2026-09-26 04:06:20保持，见install-main-2228-device-only.json。用户已亲自在模拟器解锁，install-main-2228-preunlock随后完成；该长amstart区间跨越用户解锁，不能作为启动性能。原生r4后普通包再次恢复，install-main-2228-restored-r2核实设备字节/UID/firstInstall。

## 实际运行结果与未闭合项

首次2228原生尝试发现模拟器进程退出，安装前中止；原因未知。恢复原LDPlayer实例1前后旧包/UID/firstInstall一致。第二轮在重启后休眠/系统锁屏条件下取消，无fixture结果，不能当通过。用户随后在模拟器自行解锁，未收集密码或更改凭据。

native-acceptance-2228-r3与r4各有5个成功场景、1处TestFailure，driver均退出1。通讯录切换已通过；唯一失败是同步后Synthetic room64条目hit-testable为0，源码745/1627，inset0，hit path含模态遮罩类型。r4精确观测到“保持来电提醒”的标题/源正文前缀/两按钮，并通过正常“稍后设置”关闭，确认标题消失，但同一失败继续，故不能把该引导认定为唯一根因。外部观察器后续RuntimeError导致整体NOT_VERIFIED，已确认的这次操作单独保留。没有额外terminal Multiple exceptions。六报告行或诊断行数不代表六测试通过。

普通main2228的all-main-2228-r1在无并行主机构建/测试时完成14个不同房间逐一force-stop→MAIN/LAUNCHER，零真实发送。14/14观察到content_ready，但只有1个roomHIT（ordinal4，内容621ms），13个MISS内容815–7163ms。route_push_started16–89ms；首次房间frame238–596ms。13次启动headUncommitted，第一次列表startupHIT但房间MISS。PASS仅表示内容被观察到，不表示缓存目标完成；trace总时长可能包含后续网络同步，不能当首屏耗时，也不是物理触摸→实际呈现。

ordinary-head-observation-2228-r1只读VM观测：列表cacheHIT1263ms、首投影1679ms，完整检查2295→4061ms、SDK5171ms，证明合法列表先于完整检查。稳定revision4/active0/verified/no poison下，owner的内存heads0→6→7→15，随后depth40；日志多次projectionCommitSuccess。后台能重建，但仍有失效→补齐窗口。VM采样本身扰动时序，不把这些绝对值当性能或纯SQL。79秒后的过期VM引用产生null字段样本，不能解释为owner退出。普通样本中startupAdmission存在，不能把这轮问题归因于该字段缺失。

早点击补充early-main-2228-r1只抽前三房：首房HIT/content260ms，后两MISS1084/868ms；脚本整体PARTIAL是主动limit3，不能替代14房全量。即使请求click-at-list，实际是否在SDKready前点击以每行click_after_full_sdk_ready为准。

仅failed-hit诊断扩展b15bcb35：有界hit-render祖先runtimeType、对话框finder数及四静态title布尔，原断言/SQL闸门/产品未动，DOMAIN→QUALITY PASS。定向6PASS/90秒、analyze0/40.7秒；首次analyze因相对输出目录不存在而未启动，不算通过。普通产品仍d1，诊断APK独立源码/哈希绑定，构建进行中，不复跑未变产品的等价共享门禁。

Android原stay_on_while_plugged_in=0、screen_off_timeout=60000ms。r3临时0→7并finally恢复0；随后root持有跨验收唤醒lease，当前7，必须最终恢复0并记录。r4脚本如实恢复其进入时的7；不把该子lease当最终恢复。

下一步：完成b15诊断APK→原生六场景继续定位真实遮罩，任何未知对话框不盲目关闭；同时审查缓存失效后首批覆盖与当前房优先准备的最小修正。最终必须恢复普通main、root唤醒原值、记录真实缓存命中与未过门禁；无生产发布。

14个早期合成worker DB的递归和精确叶子清理均被自动审批以blocked by policy拒绝，未删除、不再尝试。它们在忽略的.dart_tool验证夹具目录，不进入APK。该限制不用于宣称验收通过。

## 2227阶段历史报告（保留当时检查点）


当前检查点：产品与共享门禁完成；普通包已首次保数据安装，原生最终验收与无构建负载的14会话比较尚未完成。不得把本文检查点视为最终交付或所有房间同因的结论。

### 范围与来源

授权：查找快照拒绝后的慢路径，最小身份绑定后显示合法缓存，完整检查后台继续；推送Debug到模拟器。未授权生产发布，本次不改正式弹窗或下载入口，未发送真实消息。参见[任务](../workflow/tasks/2026-10-18-room-entry-readiness.md)、[计划](../superpowers/plans/2026-10-18-room-entry-readiness.md)、[ADR](../adr/2026-10-18-room-entry-readiness.md)。

产品源码60707939f52a4c4fb63c064743161d100a72c288；测试夹具修订9671166606be863bcd794b56275f0c8b6fff9402。后者只改startup_local_projection_entry_test.dart，运行时、依赖、Android配置与前者完全相同，product-equivalence.json绑定普通APK与共享门禁的复用范围。证据根为本工作树docs/verification/artifacts/2026-10-18/room-entry-readiness/，不复制全部原始产物到primary。

### 根因与行为

消息列表、搜索、资料等受管理的入房路径共用AppHome。旧快照未获准或房间头不可用时，取得合法租约后仍先await PreparedRoomPageEntry.prepare，再push页面；因此完整SDK即使已就绪，仍会等待本地时间线准备。2225无并行主机构建的15次尝试有13条有效trace：12条lease→push1865–3201ms，1条305ms；身份lookup10–18ms、租约0–4ms。该区间含准备与调度，不能称纯SQL时间。

后续全高度行枚举纠正为14个不同会话条目，原15计数包含裁切行，原失败/歧义样本保留。2226观测到businessRefreshPending与headUncommitted两种全局拒绝，故不能把全部房间归为同一准入原因。2226提前推页虽1–6ms，但MISS内容仍583–2563ms，不能用空白页面当作缓存首屏成功。普通2226单样本HIT内容322ms、第一投影2007ms、完整身份检查2514→4540ms，证明有效缓存可以先显示，但不代表14房间均已解决。

本次修正：

- 已绑定账号、安装、设备、指纹、数据库代次、密钥、注册设备、摘要、隐私及tombstone检查仍前置。有效pending_refresh_operation本身不再拒绝已提交AEAD缓存的只读显示；畸形pending、未提交头及其他拒绝条件仍关闭。prepare/commit写缓存权限仍被pending挡住，缓存显示不授予业务验证或发送权限。
- 合法租约取得后推入房间；有效缓存先显示真实气泡。canonical时间线、锚点与完整恢复在同页继续；无有效缓存只显示真实的房间内pending画布，不伪造空历史。按钮/键盘发送等待持久journal就绪并保留草稿。
- 缓存采集使用有界canonical数据库40房间×每房40事件，避免为首屏等待完整getTimeline/postLoad；无数据库保留旧fallback。排序、头像、媒体、隐藏/撤回过滤、AEAD及全局隐私失效保留。SQL/解密后、发布及提交前校验准确client/DB/Room/历史代次/permit，所有订阅finally取消。
- 默认复制/哈希移出UI isolate，只传路径；复制源hash、独立快照hash、最终源文件/sidecar检查仍完整执行，SQL和密钥留在调用方。不宣称身份检查墙钟已稳定缩短。
- 迟到结果校验准确租约、账号、业务epoch和代次；隐藏过滤先于首次controller发布/刷新，sender只在当前owner首次成功刷新后注册。完整身份/SDK与业务授权继续约束实际派发，终止刷新撤销缓存页面及排队owner。

### 测试与审查

DOMAIN/SPEC后独立QUALITY两阶段设计与实现均通过，含受保护的冷显示权限ADR。诊断新11阶段仅本地，最终/检查点上传均过滤，保留部署协议。实际SQL标记未出现在设备trace，阶段区间不称纯SQL耗时。

- RED entry复现held timeline挡住页面；worker/default与closed diagnostics缺API编译RED保留。GREEN入房6、原身份24、真实加密worker/生命周期30、初始实际main5、上传/composer23通过。affected-regression148通过但1个不存在的测试路径导致exit1，正确composer另外覆盖，不能说原命令全绿。
- RED pending-cold与held-postLoad分别证明原行为；最终38 admission/store覆盖有/无有效pending的拒绝矩阵、显示只读及writer拒绝。真实非空加密首屏采集保持40/40预算、元数据/头像和隐私过滤；SQL后代次/Room/协调器变化及读取异常均不能发布新head。
- 实际main六场景与无DB fallback7通过，终止刷新401撤销/零发送通过；初始44通过伴drain警告保留，新terminal独立MXID后7通过/82s无该警告。phase2-focused-final109通过。postLoad竞态使用完成/进入信号，不依赖3秒任意延迟。
- 最终共享源607：2026-10-18 14:10:05→15:02:07UTC，6261可见PASS/9SKIP/0FAIL，analyze0，source_stable=true；Olm3.2.15与SQLCipher4.10.0实际DLL SHA和pub锁绑定receipt。9项既有跳过未消除。后续fixture-only967定向7PASS/91s、analyze0/18.7s；按change-impact复用未改产品覆盖，并非声称全量命令跑过967。
- Python原递归目录扫描因生成产物无限扩大而取消，不算通过。实际5164个Git跟踪文本输入的等价禁用字面量扫描通过，相关有界平台22PASS/1deselected。早期平台28及UI契约34组件/540屏通过。aggregate verify.ps1缺.env未执行，不导入生产凭据。

原生初版2227两轮各5/6成功、exit1，第一例在后续导航失败，均保留。r1旧固定泵后未找到同房再入页，根因未知；r2后续通讯录不可点击。r2只读观察四次warm打开cacheHIT、push1–3ms、内容93–154ms，排除这些样本等待旧SQL，不能解释r1。经DOMAIN→QUALITY批准，fixture改为准确route.completed、当前路由及真实缓存气泡，SQL仍关闭；旧200ms观察、等待泵数/耗时与失败diagnostic_only均保留。它验证先于SQL可用，不建立200ms性能承诺。最终原生结果待追加。

### 构建、安装与时长

普通main APK SHA256 356e0a980fadab1d8a6eccd0adac0d6addf00d976252c55afe9b7ad084d3023c，126130522B，standard/x86_64 Debug，仅供本模拟器；固定签名75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。源码→Apktool2.12.1→zipalign36-P16→固定签名→清单/DEX/资源/库/资产语义检查通过。普通构建14:20:17→14:33:17UTC，与共享门禁并行在独立blob核对的archive，继承receipt中“tests complete before build”文字过宽：全量实际在构建之后、交付之前完成。

15:12:00→15:12:40UTC首次install-r通过，设备APK SHA、UID10090及firstInstall2026-09-26 04:06:20保留；构建重负载下activity13272ms不用于性能结论。普通UI已观察7条会话行，无发送，数据兼容证据ordinary-compatibility.json。最终诊断验收之后须恢复同一普通包并补无构建负载的14房冷启。

诊断r3构建在Gradle PreCreateOutputParentsStep发生parent空指针，未签名/安装，失败保留。改用上一成功构建的Y映射后r4源码构建通过；持久根因未确定，不宣称修复Gradle。其完整重建比较仍进行中。各工具精确起止见step-timings/receipt；并行墙钟不求和，无法追溯的主动分析时间为未知。

### 卫生限制与下一步

自动审批拒绝14个早期失败测试的合成加密worker DB清理，包括递归及精确叶子非递归尝试，仅返回blocked by policy。未执行删除，不再尝试；它们在忽略的apps/mobile_flutter/.dart_tool/docs/verification/artifacts/2026-10-18/room-entry-readiness/fixtures，不进入APK；新夹具用绝对路径并正常清理。fixture-cleanup.json保留。

下一可执行：完成诊断r4重建语义校验→原生六场景→恢复普通APK→14可见会话逐一真实冷启动，无实际消息发送→最终时长/缓存命中与拒绝分布、审查/索引同步。未发布生产。
