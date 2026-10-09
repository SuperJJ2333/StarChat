# 缓存优先、快滑稳定与静态表情最近使用

用户本轮四项要求：冷启动消息列表先显示历史缓存；持续快速上滑不能因分页发生索引漂移/跨天跳转；快速切房/旧索引房间先显示缓存消息气泡；表情面板默认静态、最近16枚去重按使用时间倒序两行。当前调查/实现，未修复或发布声明。
可靠调查时刻2026-10-09T13:17:40+08；更早准确起点未知。正式Android0.4.42+2211已发布，iOS2205保持；本轮只修复/验证及延续私有debug，不自动正式发布。
复用managed W: android2205-sync-deadlock树，b09bf2f2+既有WIP；先前2211冻结1935输入，全量5730/9/native5/analyze0不能代替新改动验证。
计划：[执行计划](../../superpowers/plans/2026-10-09-cache-first-fast-history-emoji-recents.md)。所有权：root启动/list/cache/SDK及集成；fast agent controller/viewport/anchor/adapter，room_page需协调；emoji agent panel/recent存储与专项。不并发编辑同一文件。

| ID | 期望 | 当前状态 |
|---|---|---|
| C1 | 有缓存冷启动列表先可见，后台整理不阻塞首屏 | 已实现、专项/原生通过，私有debug2212已安装 |
| C2 | 快滑连续分页不跳锚点/不重复乱序，缓滑保持 | 已实现、30重叠fling锚点及原生通过；真实弱网组合待验 |
| C3 | 快切A-B-A/旧格式索引房间缓存先可见，退休任务不覆盖当前房间 | 已实现、生命周期/原生加密旧历史通过 |
| C4 | 每次打开默认静态，最近16去重倒序两行8列并跨打开/重启保存 | 已实现、账号隔离/面板/原生通过 |

安全约束：不改E2EE/密钥/鉴权，不新增明文消息持久化到Preferences或服务器，账户/房间隔离，保持有界窗口/内存；不要等待全历史索引才让用户可操作。先复现根因RED再最小修复、专项/原生/共享门禁、SPEC→QUALITY，版本/构建依赖真实验证结果。
下一步：读取实际bootstrap/room列表和timeline入口→延迟/旧索引/快滑RED→分域修复。

## 实施阶段 2026-10-09T13:25:44.0477257+08:00
已按 subagent-driven-development 分三域执行：cache_first_restore负责SDK/Matrix快照与首屏；fast_history_fix负责controller/viewport/anchor/adapter及需要时room_page滚动区；static_emoji_recents负责面板/账号级表情标识存储。root负责room_page提及恢复与账号接线、真实动态测试显式tab、集成/门禁。
root复现：群聊打开在cachedtimeline前await openMentions，提及Prefs写入延迟时controller为空；mention-red.log exit1为预期缺陷。已移到首屏准备后独立可取消恢复，初次GREEN exit0；增强到渲染列表断言后待回归。原生动态验证显式superEmoji，以保持默认静态改动后56动画覆盖。
来源：managed docs/verification/artifacts/2026-10-09/cache-first-fast-history-emoji-recents/root/；无生产变更。模拟器online、debug实际0.4.42+2211，firstInstall2026-09-26保持。

### 2026-10-09T13:34:24.7204862+08:00 集成进展与约束
C2已复现固定裁100导致可见高气泡丢失，真实2500px/s RED→GREEN、12次10000px/s变化高度fling≥3窗口移动/<1px锚点差，由fast域补全回归。C1/C3cache域已准备实际1M旧fragment/copying状态、延迟positions及初始预览修复阻塞测试；等待串行RED。C4源已冻结，SPEC只读审查；完整最终测试未完成。
Flutter测试并行曾出现共享构建输出交叉，已停止并行Flutter，按fast→cache→emoji→root门禁串行；诊断退出/取消保留，不能把编译失败当行为RED。
Root群聊mentions延迟写入RED1→渲染列表GREEN1，放到cache首屏后；账号表情接线完成。扫描器另有历史背景内存风险：不能直接给mention scan加resident裁剪，未知readboundary会导致新侧提及丢失；尚未变更扫描规则。需把该风险与本次UI有界窗口证据区分，不能宣称任意规模零卡顿。
生产只读2026-10-09T05:30:24Z确认Android2211/iOS2205、官网candidate2209，无写入。构建helpers已准备2212/0.4.43但产品版本未递增/未构建/未安装。

### 2026-10-09T13:58+08 规格/安全审查阶段
C1/C3：缓存房间列表与初始持久消息ID先发布；历史计数/可选预览/关联房间后台继续，预览独立串行lane不阻塞选中房间head。SDK6项首屏专项/59项最终SDK回归通过；SPEC接受。QUALITY发现瞬时提及恢复失败后UI不重试P2，root正在补行为RED→GREEN；不要把安全审查中的NEEDS_CHANGES说成完成。
C2：可见事件ID保留而非盲目裁100，已过高气泡/12次停稳fling专项；额外30次上一轮惯性未结束的fling出现硬分页边界RED，连续修复曾引入延迟forward回归，agent已隔离到初次ballistic通知过早推进，正在校正/回归。尚无最终连续快滑及原生结论。
C4：默认静态、账号级16枚最近使用两行8列实现；SPEC抓出Moments未知身份落原始token的prefs键P1，已改成Matrix ID/JWT字符串sub/未知不持久化，行为RED→GREEN。QUALITY抓出滑动中换tab遗留maintenance锁P2，已补RED→GREEN并只在实际换tab/销毁清理，账号更新不提前清理现存滚动；C4审查接受。完整最终合并门禁/新Android验证待执行。
全量verify环境缺.env，不导入生产秘密；拆分适用门禁，policy三项PASS可复用。新增原生wrapper复用cache6/continuous/lifecycle案例，SQLCipherFactory只通过测试注入；未构建新APK、未改线上设置。
下一步：continuous agent回归/释放Flutter→root提及重试RED/GREEN及表情/本地列表专项→最终共享/analyze/边界、原生模拟器→固定签名2212保数据debug交付。

### 2026-10-09T14:27+08 最终共享门禁阶段
C1/C3、连续C2、C4及两处审查修正均SPEC→QUALITY接受；C2 30次重叠fling/32专项、C1/C3 SDK59/初始缓存6、集成64/生命周期9通过。瞬时mentions失败重试：实际新增事件RED→GREEN，已退出房间延迟完成不发布tracker；完成尾部表情队列只保留in-flight，不长留上次store/zone。
跨widget夹具旧FakeAsync Future导致整文件cancel等待，独立账号诊断证实后仅隔离metadata夹具，未改生产scanner/owner drain；临时phase/operation打印已全部移除。第一轮全量5749PASS/9条件skip/7失败，均为旧全量等待/attachment时机假设（6）和固定100ms磁盘完成假设（1）；五文件保留原安全/清理/计数竞态/零无关刷新断言的31专项已通过并独立双审。全量失败命令/receipt保留，最终全量第二轮运行，不能把第一轮称全绿。
源码成对版本0.4.43+2212、版本契约3PASS、正常pubget锁12ae6742不变；最终1941输入manifest91085d0c33a0a54a0543c438b8f3d94908a8439aeb869955322c053f894c6f89。已发布2211实际1935输入对比新增6/修改33/无删除，避免以HEAD混入之前WIP。最终analyze0、边界377/23条件skip、UI契约34components/535screens通过；policy3复用。完整verify缺.env仅拆分适用门禁。
14:23:57+08生产只读确认正式Android2211/iOS2205/candidate2209未变。新包尚未构建/安装；下一步第二轮共享完成→native cache/连续/生命周期及56动效+真实键盘→原生加密存储维护相关→正常依赖恢复/冻结→固定75b31常规重建x64debug→保数据安装。

### 2026-10-09T14:53+08 最终验收与打包
最终共享5757PASS/9条件skip、analyze0、边界377PASS/23条件skip、UI契约34/535及policy3通过。SPEC后QUALITY接受各域及后续夹具修正。原生缓存/生命周期15PASS；连续fling最终独立1PASS；emoji6PASS（默认静态最近16/56WebP/10真实IME）；原生维护/加密存储24PASS（25万/百万旧索引、快速切房、真实IME），退出均恢复IME并清理自建helper。
原生连续用例首轮异步观察调用tester/expect触发TestAsyncUtils guard，改为Finder/RenderBox/expectSync，保留相同事件ID/<1px/200窗口断言；最终host1PASS/native1PASS。全量门禁后只变此测试文件，生产源码/生成输入均一致，gate-reuse-receipt精确绑定最终build manifest f5eab55688d107490b3c079600310627339572cf1280367811817a75732a0d23与5757门禁，不重复全量。最后host初次误填rooms路径不存在，失败命令保留，matrix正确路径通过；非功能RED。
14:50:29+08只读正式仍Android2211/iOS2205/candidate2209。0.4.43+2212私有x64 debug运行run-20261009-145050-debug源码构建已完成，常规重建/验签中；尚未安装，不可宣称已交付。下一步26门禁与安装-receipt→仅内存读取日志的启动错误计数→报告/索引收尾。
边界：没有真机release/profile；连续手势和实际弱网回复同时发生尚无新专门组合测试；未知百万ordinal首查询仍约8.8sec、native100room恢复2.46sec，缓存首屏绕开此路径；background mention scanner无界未读体保留风险未改，不能宣称任意历史/设备零卡顿。没有生产发布/新弹窗写入。

### 2026-10-09T14:53:15+08 私有debug安装完成
常规重建26门禁通过，artifact SHA129ec7876b9030b217d9485831e716657bde01561fcd0d08134ada3f4498f129/125827617bytes/固定75b31；安装-receipt确认模拟器2211→2212、首次安装时间不变、15秒稳定PID，无卸载清数据。56WebP私有cache注入完成；启动Dart/Flutter/Java原生错误计数均0，未保存真实用户日志。交付报告docs/verification/2026-10-09-cache-first-fast-history-emoji-recents.md记录所有验收、门禁复用、失败诊断和边界。C1–C4已实现并交付私有debug；正式Android2211/iOS2205/candidate2209及弹窗无写入。下一步真机release/弱网组合验收，公开发布须单独构建ARM64并执行平台门禁，不能分发x64 debug。
