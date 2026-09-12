# 历史检索与群聊接收延迟

开始：2026-09-12约22:04+08（分钟精度，首次精确工具时间22:05:03）。用户反馈日期等待十几秒、定位五天前后双向滚动卡死、50+发送者群聊接收延迟50秒；后确认设备Debug0.3.87/2096、是别人发出后很久收到，准确时间/群名未提供。
授权：定位并修复、沿用Astra/Terra分工与Debug Mi6用户自测。当前工作树.worktrees/offline12；根工作区脏文档/锁文件不动；不push/生产部署/重启/迁移，不造生产负载、不读取正文/密钥、不修改手机网络/清数据。
计划：[实施计划](../../superpowers/plans/2026-09-12-history-latency.md)。证据目录docs/verification/artifacts/2026-09-12/history-latency/。

## 当前状态
I0已完成并提交9e87c8a09578dbc55745ce0546fd6e29854b7102（父401b3938与f6405c04）。以下保留初始核对经过：ADB确认Mi6 cbd0156b实际2096，lastUpdateTime2026-09-12 19:43:17。原本worktree401b3938/2094，根main已f6405c04但d145合并父6db66f0c+aac3d806，不含401；2096重建脚本指向根工作区。新分支codex/history-latency-20260912从401 merge main，唯一冲突contacts_page.dart。
实际创建terra_history_dates显式gpt-5.6-terra并完成H1只读，第二新代理与旧代理唤起均因agent thread limit拒绝；目前只用这一已确认Terra串行执行，root独立审查H2/H3。没有静默模型替换。
Terra独占contacts_page.dart冲突与Flutter runner；root负责计划/证据、H2/H3只读。接着root审查合并后再H1或H2小批。真机功能由用户测，本轮只有ADB只读版本检查。

## 已确认与待确认
- H1：实际calendarMonth加载先loadThrough月初，按60条串行本地/远程分页，再allMessages投影汇总日期；main与401的日期/搜索/历史逻辑一致。确认是客户端加载策略缺陷，不能据此估算一次真实网络RTT或宣称服务器健康。
- H2：自动换窗、锚点restore/jumpTo、scroll监听和prefetch循环是具体候选，尚无失败用例，不声明已定位。
- H3：仅确认接收端；未取得对应时间段的分层遥测，50秒是否来自网络、服务端队列或客户端处理仍待证据。

## 验收台账
| ID | 要求 | 状态/证据 | 下一步 |
| --- | --- | --- | --- |
| I0 | 保留2094/2096两边改动并对齐基线 | 已提交9e87c8a0，局部审查通过 | 最终整合门禁 |
| H1 | 日期首显不整月串行扫描，旧日期仍可检索 | 代码根因已确认 | 有界本地索引/扩展设计与RED |
| H2 | 定位历史后上下反复滑动正常 | 已有真实RoomPage RED/GREEN，候选待收尾 | clamped边界与真实取消回归 |
| H3 | 分解群聊接收延迟并修复证实的阻塞 | 调查 | 跳板只读汇总与SDK链路 |
| V/D | 完整验证与必要新Debug安装 | 未开始 | 待实现冻结 |

## 22:26+08 阶段更新
- I0 contacts冲突已由Terra合并，Astra实际diff复核保留presence三态/迟到请求保护，并以弱引用API+repository作用域节流。contacts/profile定向50通过（contacts-merge-focused-test-v3.log）；I0尚未提交。
- Astra检查未冲突main输入发现：MomentPreviewCache全局实例按目标userId缓存且fetcher仅首次配置；冷启动组件不会配置fetcher，只有AppHome resumed预热。需补账号隔离、独立入口加载与迟到请求回归后再发布；属于2096输入缺陷，不是本任务已修复结论。
- H2已交既有明确Terra执行真实列表RED测试，暂只拥有test/ui/chat相关文件；共享产品代码待审查根因后串行实施。
- H3服务端只读证据server-baseline.log/server-request-summary.json：采样前3小时/messages P95 144ms、send P95 158ms；当前资源未满，不能排除用户事件时瞬态或队列问题。sync约30s是长轮询，不能解释成消息延迟。
- 22:25:59+08被动读取手机logcat，21603行只提取允许列表数值，没有Process sync/Get event list样本；device-sync-benchmarks.json未保存正文/房间/账号/令牌。未执行真机功能或网络测试。
- H3具体候选：SDK每条消息storeEventUpdate都复制并Box.put整个timeline ID数组，sqflite_box在批事务中仍每次立即JSON编码并排队一次INSERT，可能造成批量写放大。尚待真实SDK数据库50 sender合成测试，不能声称已证明实际50秒因果。
下一步：Terra H2 RED → 最小修复；随后I0缓存修复、H1日期检索及H3验证。

## H2 RED与实现授权（22:31+08，分钟精度）
Terra用真实Flutter reverse ListView+TimelineScrollAnchor复现：restore的jumpTo使仍按住的drag由scrolling=true变false（h2-reverse-anchor-drag-red.log，exit1）；Astra亲读测试及Flutter jumpTo先goIdle源码，确认用户活动手势被程序定位取消。另200条5000px高行的locator在256帧上限后返回false（h2-reveal-bounded-window-red.log，exit1），这是极端高度边界测试，不宣称用户实际有此消息规模。现有14个RoomPage/anchor/离线回归通过（rerun日志exit0）；无进展prefetch无限循环未独立复现，不当作证实根因。
批准Terra独占room_page、timeline_scroll_anchor、message_scroll_locator及相关tests实施：活动手势中可预取，但延后可见换窗到ScrollEnd并重查边界/方向；避免先换窗后拿陈旧anchor把用户拖动回滚。旧restore遇新手势/取消应停止。locator基于实测行索引/高度有效定位，有界、可取消和无进展退出，不简单扩大次数。追加实际RoomPage反向连续拖动/边界/定位取消回归，Astra再审。

## 环境预检与诊断限制
22:33+08预检（分钟精度）：C盘剩14.4GB，D盘73.9GB；worktree有scripts/verify.ps1但无.env。最终全仓verify先按运行手册检查并记录阻塞，不导入生产秘密造环境。
当前H2补充真实RoomPage 1000条合成历史，持续反向拖动触发自动旧窗口切换也失败（h2-room-page-drag-red-v3.log exit1）。Astra已审实际测试，不以孤立helper替代真实入口。生产SDK未发现接收路径强制每消息等待1秒的代码；room.dart的1秒重试在发送路径，不与本次接收端报告混淆。

## 22:54+08 H2批次审查 / I0继续（分钟精度）
H2候选定向21通过，h2-focused-green-final-v4.log exit0；targeted analyze无问题exit0。Astra亲读最终diff及测试日志：用户drag/ballistic期延后换窗，notifier false再消费pending；标准行保持3屏seek，超高已测行允许自适应，修复最初懒构建峰值38的回归，未放松原<30断言。
尚未终验：Astra指出纯clamped边界可能未装notifier listener、未到newer-edge的反向拖动未取消迟到earlier请求、主动取消locator不应显示未找到；已要求定向补测和小修，排在I0当前独立批次之后。不能把21过称为所有边界已过。
Terra当前独占I0 moment_preview_cache/moment_profile_preview/app_home预热区域与对应测试，按API+sessionEpoch隔离，冷启动自主配置，隐私失效generation屏障；root只读审H2和维护记录。
H3增加server-key-request-summary.json：最近3h keys/query149次P95 21ms、sendToDevice39次P95 28ms、keys/claim7次P95 24ms；无事故时刻关联，不支持按猜测修改密钥队列。
空目录清理：apps/mobile_flutter/docs/verification/artifacts/2026-09-12/history-latency已只读确认为空；root尝试绝对路径/非链接/空检查后的非递归Remove-Item仍被自动审批blocked by policy拒绝（无进一步原因）。未删除，已告知用户，禁止再次绕过。只影响误建空目录，不影响Git或产物。

## I0审查通过 2026-09-12T23:05:50.904964+08:00
Astra实际审查API/epoch缓存、冷入口、隐私/revision迟到隔离、403撤权、预取终止与两个独立预览的通知路径。额外跨组件RED精确复现build期间setState；最终使用同步失效+按scheduler阶段延迟/合并通知与监听快照。i0-focused-green-final-v4.log 13通过exit0，i0-targeted-analyze-final-v4.log无问题exit0；contacts/profile合并此前50通过。I0局部规格及质量/隐私审查通过，可作为整合基线提交；全量门禁仍待最终候选。H2三个审查收尾由Terra继续，未宣称H1/H3完成。

## 23:17+08 H2收尾与执行环境（分钟精度）
I0合并提交9e87c8a0；旧terra_history_dates因执行预算耗尽不能继续，已实际创建新的terra_history_navigation，明确model=gpt-5.6-terra、fork=none接手。再次创建独立H3代理失败agent thread limit，并未创建；目前仅一个执行Terra串行，Astra做独立diff/调用链审查。held-history真实RoomPage回归已补：旧请求挂起时同手势向新方向反拖100px、仍在旧边缘阈值内，迟到完成不再切回旧窗口，模型≤200。该测试第一次失败是fixture未到旧边缘，并不是新的产品RED；原产品RED证据沿用既有真实拖动失败。继续补纯Clamping边界与真正跨帧取消，替换依赖回调调用次数的locator测试。
下一步：H2审查提交 → H3真实SDK数据库合成50 sender量化 → H1日期有界定位实施，保持共享文件串行。H3实际50秒延迟仍无事故时刻关联，不宣称已修好。

## H2局部验收 23:21+08（分钟精度）
Astra亲读最终三个产品文件diff、真实RoomPage测试、frame间取消fixture与日志。规格符合性：活动手势/惯性不被jumpTo抢占，边缘延后换窗，反向操作撤销旧pending，locator可取消且200模型不扩容；质量检查：listener生命周期、迟到generation、无新业务/API/财务/E2EE边界变更。h2-room-anchor-locator-final-terra-v2.log 24通过exit0；h2-room-anchor-locator-analyze-terra.log 无问题exit0。clamped和跨帧取消是新增GREEN覆盖，原始产品RED仍为h2-reverse-anchor-drag-red、h2-room-page-drag-red-v3及超高行定位RED。首个日志创建命令参数错误发生在Flutter启动前，不算执行失败测试。
H2可独立提交；H1整合后还需跨模块回归及最终候选全量门禁，Mi6手势用户自测。Terra现仅拥有新sdk_receive_burst_benchmark_test与receive-burst证据，H3先测不改产品；Astra维护记录和H1架构。

## H3存储测量完成 / H1a开始 23:27+08（分钟精度）
Astra亲审sdk_receive_burst_benchmark_test实际FFI代理、SDK storeEventUpdate/transaction调用、有效seed时间顺序、实际SQL写入计数、replay与close/reopen断言。最终v3两项通过，analyze-v2无问题exit0；首次ID fixture字符串误写重复导致失败，不算产品RED。1500历史+50sender：50次全索引写，934395字节对最终18981字节；instrumented action/commit/total=24756/9539/34295µs。10000历史：50次，6459395对129481字节；64545/24477/89022µs。计时含计数器utf8开销，只是桌面FFI SQLite存储阶段；无真实加密/SQLCipher/Mi6/生产50人并发结论。确认写放大但未证明50秒来源，因此不按猜测重写Box事务或密钥队列。
H1a已交现有显式Terra实现公开可选日期/context能力和对应SDK fragment正确性，暂不改RoomPage/calendar UI。Root批准计划追加分批约束及loaded-fragment撤回边界；后续再H1b串行UI接入。尝试新建显式Terra同步阶段诊断代理仍被thread limit拒绝，未创建；H3阶段计时能力排在单执行者后续，不声称已有第二执行代理。
构建脚本已从前次固定签名流水线复制到当前任务artifact，RepoRoot默认修正offline12；尚未构建/安装，没有新版本声明。
