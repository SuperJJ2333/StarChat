# Cached room entry without pre-navigation wait

## 恢复入口

用户授权：在五项冷启动/入房机制说明后要求“好的，请你推进，并且推送debug版到模拟器测试”。目标是有效缓存可立即入房、滚动，SDK恢复完成不会导致缓存提前失去用途；优先缓存置顶及列表前部会话。仅Debug模拟器交付，无本轮生产发布。

已有批准计划：docs/superpowers/plans/2026-10-17-startup-local-projection.md的2222跟进。工作树interactive-cache-startup，基线049c2f9b（正式2221已发布，产品45355）。Root负责文档/版本/测试门禁/打包安装，cached_room_entry独占产品与专项测试，独立规格后安全审查。21:11+08读取设备emulator5556 online，源码0.4.52+2221，工作树起始clean，无.codegraph。

## 验收台账

| ID | 场景 | 状态 |
| --- | --- | --- |
| CE-01 | SDK未完成，点击缓存房间，持有后台读取仍出现真实气泡并可滚动 | RED/GREEN与native-r2 PASS |
| CE-02 | SDK已恢复但本地timeline读取被延迟，点击仍从有效缓存即时打开，同页合并不跳锚 | 主机及native-r2 PASS；仅有效缓存；首次native信号失败保留 |
| CE-03 | 超过40会话：置顶/草稿/列表前部优先，容量有界，点击不排在整批恢复之后 | 65房间/中途点击重排断言PASS；失效后读取自身SQL边界另记 |
| CE-04 | 删除/隐藏/撤回/账号切换/撤销/成员变化不得复活旧内容；待发持久与实际发送权限分离 | 专项/6155全量及独立SPEC→QUALITY PASS |
| CE-05 | 真main入口Android延迟场景通过，普通main固定签名Debug安装保留UID/firstInstall/数据 | native-r2五场景PASS，普通main23:45保数据安装，冷启动HIT/入房滚动观察通过 |

初始根因：hasLocalDisplayProjection同时控制展示和未初始化生命周期，SDKready后false；AppHome推route前等待多个本地准备；投影writer取快照前40未复用UI最终排序。不能简单删pending条件或把加载页挪到点击前。当时执行阶段：一个实施者建立故障反例并修正；最终交付结果见台账及末尾记录。

证据目录docs/verification/artifacts/2026-10-17/cached-room-entry/。完整测试使用既有已核验Olm/SQLCipher DLL和短路径，先冻结再全量；verify.ps1缺.env若仍存在应记录未执行，不导入生产秘密。保留旧版全部失败/已知限制，不视为本轮通过。

当前交付：0.4.53+2222普通Debug已装emulator-5556，等待用户自行测试；下一执行步骤为根据具体反馈复现，不发布生产或重复构建。阶段开始21:11+08，最终证据核对23:51+08，精确工具耗时以回执为准。

21:16+08：真实main反例red-entry.log验证预期失败：post-SDK SQL仍held时RoomPage数量0，说明延迟在push前。独立design.md完成SPEC→QUALITY受约束设计批准；原globalpreinit能力保持，新增房间展示能力区分原投影与新canonicalhead，permit/owner/historygeneration/失效边界保留。ADR已补充，代码审查仍待冻结。允许增加room_timeline_controller.dart的一次性同账号durablejournal绑定；输入仅在持久队列准备后开放，不挡住浏览。

版本预检先得到17PASS/1FAIL（iOS构建工作流版本元数据尚未同步）；补齐对应六处源码元数据后18PASS/12.46秒，f32c163e；没有触发iOS构建/发布。模拟器旧2221 UID10090/firstInstall2026-09-26 04:06:20，候选2222。verify.ps1预检缺.env，仍不执行需该配置的全仓聚合；最终产品相关门禁另跑。

21:22+08：独立审查批准离线canonical内存展示许可的受约束扩展；必须独立permit类型、持久pending/blocked隐私屏障只读检查且不放入点击路径。允许实施者增加coordinator/session_store及专项测试，ADR已记录；磁盘写入/业务认证门禁保持。下一步冻结实现、SPEC→QUALITY复审，再执行一次全量与原生交付。

21:28+08：完成日志确认后台Business pendingRefresh拒绝内存head重建。独立审查追加既有admission布尔验证器限定：完整不可变身份匹配，保留隐私屏障，只允许合法同账号refresh；首次启动/磁盘/发送不放宽。禁止读完旧events后才领取新permit，必须SQL前捕获。实现仍未冻结，失败/诊断日志均保留。

21:48+08：green-entry-12实际main独立投影专项1/1通过（32秒），包括冷启动durableoutbox延迟、postSDK SQL held、非空同步后无关bulkSQL held、实际滚动及同页状态。此前fixture复用屏障、假异步等待和转场手势时机错误的失败记录保留；focused-unit-1为93PASS。尚非最终冻结：审查要求midflight新点击下一读前重排、native标记仅对实际执行场景置true，随后跑五场景/专项/analyze与最终审查。

21:59+08：四个入口场景通过，avatarhandoff仍失败；仅禁用新memoryrefresh的A/B头像1/1通过，诊断旁路已移除。独立审查确认SDK postLoad/成员表调度缺口；批准首次canonical发布前有界读取缺失成员ID对应权威DB状态（9/房间128总量），无旧头像fallback，保留permit/owner/generation检查。修复后再跑完整专项，尚未构建。

22:00+08：green-entry-final3五个共享真实main入口场景全部PASS（60秒），严格头像连续交接断言保留；finalfocusedunit93PASS。进入格式/analyze、邻接导航检查和冻结代码SPEC→QUALITY审查。root已核读完成日志，尚未运行全量/构建/安装。

22:08+08：最终审查P1（可选缓存屏障阻塞canonical列表）已red-optional-cache-fence3复现并修复；final4五场景59秒PASS，包含持久隐私屏障/poison后正常canonical行更新。补读实际发生时的有效性检查已覆盖最后异步点到发布前。审查还要求原始projection绑定首次coordinator，防同账号resume后重建coordinator复活旧head；该最后生命周期反例正在RED/GREEN。邻接导航31PASS、此前13项analyze无问题，最终freeze后仍需全量。

22:12+08：产品冻结625a23e7393841362366b526357dfdd20402b94e（13文件），implementation-freeze.json记录SHA/真实退出码。最终5入口/94单元/31邻接全部PASS，13文件analyze无问题，V已释放。恢复用例证明旧head不能复活且新permit可用，未单独声称恢复后新head填充已测；post-sync缓存另由实际main验证。下一步最终SPEC→QUALITY报告、一次全量/全局analyze和平台静态门禁，再原生Debug构建测试、普通main构建安装。

22:14+08：产品625a23e7独立SPEC→QUALITY均PASS；root文档后继2413a05a与13产品SHA完全一致。平台静态39PASS/9.41秒。flutter-full-2222已启动，明确已核验Olm/SQLCipher与独占V路径，期间不修改产品或commit；完成后方进入构建。verify.ps1缺本地.env仍未执行，不导入生产配置。

22:37+08：全量结束6144PASS/9SKIP/8FAIL，exit1/source_stabletrue，22:13:40–22:37:02（23分22秒），全局analyze因失败未启动。5发送行为失败定位到canQueue误用包含encryptionEnabled的canSendDefaultMessages；3导航静态断言过期（2项已用f32源码字面检查证明基线不存在，非完整baselineFlutter执行）。已授权单实施者限定修正事件权限排队与新负向测试、更新旧结构断言；最终delta独立审查后再全量一次，因为guard影响重试/媒体/网络恢复等63+相关文件，不能仅以失败项绿灯替代。原失败记录完整保留，V已释放给实施者。

22:44+08：原8失败组及新增负向54PASS/9秒。扩大发送/启动组130PASS/1FAIL，定位SDK pending混合旧local-cache-first与独立seeded恢复；旧路径已有身份/数据库/Olm准入却被一刀切阻断。独立审查基于vendor真实localCacheReady条件批准非projection+isLogged+encryptionEnabled的受限旧路径例外，保留真实Room/join/eventpower；新的seeded恢复仍只能用有效admission。修正后重跑扩大组再冻结。

22:48+08：修正冻结e55cd1664f012f41ab8c1805366b1269d4176f0a（5文件），13文件组186/186PASS/83秒，含原8失败、新权限负向、旧/独立实际main。delta-analyze-final无问题exit0，root核验5文件SHA与manifest一致，V释放。下一步增量SPEC→QUALITY、文档后继冻结、最终flutter-full-2222-r2及全局analyze；不改版本2222，因为尚未构建或安装候选。

22:50+08：增量SPEC→QUALITY正式通过，final-source-manifest.json合并两次冻结的16文件并核验全部SHA；文档后继b53e7387。最终flutter-full-2222-r2已启动（root会话32092），固定输入，结束后自动全局analyze。未构建或安装2222。

23:14+08：最终全量6155PASS/9SKIP/0FAIL，全局analyze无问题（18.9秒），receipt全部exit0/source_stabletrue，22:48:52–23:14:11（25分19秒）。固定b53e7387开始debug-native-2222构建，尚未安装。下一步重建签名验证、原生五场景、普通main构建及保数据安装。

23:28+08：debug-native-2222全部重建/签名/语义门禁PASS，SHA7eadfc1da2b9d5e30c16b922f80674f7a0f653ee92ea63040c6acbfa1eefc1cf；覆盖安装UID/firstInstall保持。native-entry-2222 exit1：4场景完成，独立场景1257行warmRoomReadEntered=false；原生头像连续110帧及其余场景通过。原失败保留；实施者只读定位设备时序/产品差异，未修改产品，普通main尚未安装。

23:33+08：同一已安装诊断APK受控重跑native-entry-2222-r2全部五场景PASS/222.156秒，firstframe/feedback/postSDKentry/avatarhandoff全部true，未重新打包；过滤日志保存。首次失败保留，review指出bulk屏障未标识新旧代次，另须确定性核验旧读取held期间发生sync是否造成目标入房等待；实现者只编辑专项测试构建证据，尚无产品修改，普通main待该核查。

23:39+08：补充确定性诊断两次34秒相同：sync前cache有效，sync后失效，点击ownSQL=true且无关bulk仍held，RoomPage=false（自己的SQL held）。未证实有效cache被bulk挡住，未重现原native失败。诊断补丁/日志保留并恢复，mobile clean/HEADb53，V释放；产品不改，不缩小隐私失效范围。debug-main-2222已启动普通main固定签名构建。下一步普通包验证安装和真实账户冷启动视觉验收。

23:51+08：普通main全部打包门禁PASS，23:45:47保数据安装成功，APK SHA0ca7e72dd909e9c4cbb1a8f5ce1022d282ab156a3c29a454e2ea1bfb71382298/126097754B。首次cold admissionRejected加载回退保留；cold-r2 HIT先显示真实列表/群头像再SDKready。两个房间入房气泡、长历史滚动、返回观察通过，无真实消息发送。final-audit核验16源码SHA/mobile clean/当前进程fatal-ANR0/自建forward及V-W清理。任务完成Debug交付，模拟器留消息列表；生产2221不变，等待用户自行测试。报告docs/verification/2026-10-17-android2222-cached-room-entry.md。
