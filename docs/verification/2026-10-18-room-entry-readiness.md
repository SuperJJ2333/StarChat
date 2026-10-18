# Android 0.4.58（2227）缓存房间准入与冷启动验收

当前检查点：产品与共享门禁完成；普通包已首次保数据安装，原生最终验收与无构建负载的14会话比较尚未完成。不得把本文检查点视为最终交付或所有房间同因的结论。

## 范围与来源

授权：查找快照拒绝后的慢路径，最小身份绑定后显示合法缓存，完整检查后台继续；推送Debug到模拟器。未授权生产发布，本次不改正式弹窗或下载入口，未发送真实消息。参见[任务](../workflow/tasks/2026-10-18-room-entry-readiness.md)、[计划](../superpowers/plans/2026-10-18-room-entry-readiness.md)、[ADR](../adr/2026-10-18-room-entry-readiness.md)。

产品源码60707939f52a4c4fb63c064743161d100a72c288；测试夹具修订9671166606be863bcd794b56275f0c8b6fff9402。后者只改startup_local_projection_entry_test.dart，运行时、依赖、Android配置与前者完全相同，product-equivalence.json绑定普通APK与共享门禁的复用范围。证据根为本工作树docs/verification/artifacts/2026-10-18/room-entry-readiness/，不复制全部原始产物到primary。

## 根因与行为

消息列表、搜索、资料等受管理的入房路径共用AppHome。旧快照未获准或房间头不可用时，取得合法租约后仍先await PreparedRoomPageEntry.prepare，再push页面；因此完整SDK即使已就绪，仍会等待本地时间线准备。2225无并行主机构建的15次尝试有13条有效trace：12条lease→push1865–3201ms，1条305ms；身份lookup10–18ms、租约0–4ms。该区间含准备与调度，不能称纯SQL时间。

后续全高度行枚举纠正为14个不同会话条目，原15计数包含裁切行，原失败/歧义样本保留。2226观测到businessRefreshPending与headUncommitted两种全局拒绝，故不能把全部房间归为同一准入原因。2226提前推页虽1–6ms，但MISS内容仍583–2563ms，不能用空白页面当作缓存首屏成功。普通2226单样本HIT内容322ms、第一投影2007ms、完整身份检查2514→4540ms，证明有效缓存可以先显示，但不代表14房间均已解决。

本次修正：

- 已绑定账号、安装、设备、指纹、数据库代次、密钥、注册设备、摘要、隐私及tombstone检查仍前置。有效pending_refresh_operation本身不再拒绝已提交AEAD缓存的只读显示；畸形pending、未提交头及其他拒绝条件仍关闭。prepare/commit写缓存权限仍被pending挡住，缓存显示不授予业务验证或发送权限。
- 合法租约取得后推入房间；有效缓存先显示真实气泡。canonical时间线、锚点与完整恢复在同页继续；无有效缓存只显示真实的房间内pending画布，不伪造空历史。按钮/键盘发送等待持久journal就绪并保留草稿。
- 缓存采集使用有界canonical数据库40房间×每房40事件，避免为首屏等待完整getTimeline/postLoad；无数据库保留旧fallback。排序、头像、媒体、隐藏/撤回过滤、AEAD及全局隐私失效保留。SQL/解密后、发布及提交前校验准确client/DB/Room/历史代次/permit，所有订阅finally取消。
- 默认复制/哈希移出UI isolate，只传路径；复制源hash、独立快照hash、最终源文件/sidecar检查仍完整执行，SQL和密钥留在调用方。不宣称身份检查墙钟已稳定缩短。
- 迟到结果校验准确租约、账号、业务epoch和代次；隐藏过滤先于首次controller发布/刷新，sender只在当前owner首次成功刷新后注册。完整身份/SDK与业务授权继续约束实际派发，终止刷新撤销缓存页面及排队owner。

## 测试与审查

DOMAIN/SPEC后独立QUALITY两阶段设计与实现均通过，含受保护的冷显示权限ADR。诊断新11阶段仅本地，最终/检查点上传均过滤，保留部署协议。实际SQL标记未出现在设备trace，阶段区间不称纯SQL耗时。

- RED entry复现held timeline挡住页面；worker/default与closed diagnostics缺API编译RED保留。GREEN入房6、原身份24、真实加密worker/生命周期30、初始实际main5、上传/composer23通过。affected-regression148通过但1个不存在的测试路径导致exit1，正确composer另外覆盖，不能说原命令全绿。
- RED pending-cold与held-postLoad分别证明原行为；最终38 admission/store覆盖有/无有效pending的拒绝矩阵、显示只读及writer拒绝。真实非空加密首屏采集保持40/40预算、元数据/头像和隐私过滤；SQL后代次/Room/协调器变化及读取异常均不能发布新head。
- 实际main六场景与无DB fallback7通过，终止刷新401撤销/零发送通过；初始44通过伴drain警告保留，新terminal独立MXID后7通过/82s无该警告。phase2-focused-final109通过。postLoad竞态使用完成/进入信号，不依赖3秒任意延迟。
- 最终共享源607：2026-10-18 14:10:05→15:02:07UTC，6261可见PASS/9SKIP/0FAIL，analyze0，source_stable=true；Olm3.2.15与SQLCipher4.10.0实际DLL SHA和pub锁绑定receipt。9项既有跳过未消除。后续fixture-only967定向7PASS/91s、analyze0/18.7s；按change-impact复用未改产品覆盖，并非声称全量命令跑过967。
- Python原递归目录扫描因生成产物无限扩大而取消，不算通过。实际5164个Git跟踪文本输入的等价禁用字面量扫描通过，相关有界平台22PASS/1deselected。早期平台28及UI契约34组件/540屏通过。aggregate verify.ps1缺.env未执行，不导入生产凭据。

原生初版2227两轮各5/6成功、exit1，第一例在后续导航失败，均保留。r1旧固定泵后未找到同房再入页，根因未知；r2后续通讯录不可点击。r2只读观察四次warm打开cacheHIT、push1–3ms、内容93–154ms，排除这些样本等待旧SQL，不能解释r1。经DOMAIN→QUALITY批准，fixture改为准确route.completed、当前路由及真实缓存气泡，SQL仍关闭；旧200ms观察、等待泵数/耗时与失败diagnostic_only均保留。它验证先于SQL可用，不建立200ms性能承诺。最终原生结果待追加。

## 构建、安装与时长

普通main APK SHA256 356e0a980fadab1d8a6eccd0adac0d6addf00d976252c55afe9b7ad084d3023c，126130522B，standard/x86_64 Debug，仅供本模拟器；固定签名75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。源码→Apktool2.12.1→zipalign36-P16→固定签名→清单/DEX/资源/库/资产语义检查通过。普通构建14:20:17→14:33:17UTC，与共享门禁并行在独立blob核对的archive，继承receipt中“tests complete before build”文字过宽：全量实际在构建之后、交付之前完成。

15:12:00→15:12:40UTC首次install-r通过，设备APK SHA、UID10090及firstInstall2026-09-26 04:06:20保留；构建重负载下activity13272ms不用于性能结论。普通UI已观察7条会话行，无发送，数据兼容证据ordinary-compatibility.json。最终诊断验收之后须恢复同一普通包并补无构建负载的14房冷启。

诊断r3构建在Gradle PreCreateOutputParentsStep发生parent空指针，未签名/安装，失败保留。改用上一成功构建的Y映射后r4源码构建通过；持久根因未确定，不宣称修复Gradle。其完整重建比较仍进行中。各工具精确起止见step-timings/receipt；并行墙钟不求和，无法追溯的主动分析时间为未知。

## 卫生限制与下一步

自动审批拒绝14个早期失败测试的合成加密worker DB清理，包括递归及精确叶子非递归尝试，仅返回blocked by policy。未执行删除，不再尝试；它们在忽略的apps/mobile_flutter/.dart_tool/docs/verification/artifacts/2026-10-18/room-entry-readiness/fixtures，不进入APK；新夹具用绝对路径并正常清理。fixture-cleanup.json保留。

下一可执行：完成诊断r4重建语义校验→原生六场景→恢复普通APK→14可见会话逐一真实冷启动，无实际消息发送→最终时长/缓存命中与拒绝分布、审查/索引同步。未发布生产。
