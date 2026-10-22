# Android2232聊天滚动定位回归

- 用户2026-10-21反馈：上滑历史被拉回最新；冷启动入房停在旧图片而非缓存最新消息。授权排查及修复，沿用已批准interactive-cache-startup计划的滚动保持契约；本次不自动发布正式更新。
- 基线：interactive-cache-startup工作树，1036a81e，开始时干净。线上2232不包含本次后续修改。
- 开始调查：2026-10-21 18:45–18:50+08，精确起点未知。root独占生产文件与测试；独立审查只读。
- 所有权：room_page.dart、room_timeline_controller.dart、latest_message_anchor.dart、timeline_scroll_anchor.dart及匹配测试、本记录/计划/报告/本任务证据。
- 计划：[回归修复](../../superpowers/plans/2026-10-21-timeline-scroll-position.md)。

| ID | 验收 | 状态 |
| --- | --- | --- |
| S1 | 历史浏览期间补消息/回执/分页不强制回最新 | 宿主PASS；原房间待用户复测 |
| S2 | 普通冷入房显示最新缓存，补齐不落在旧图片；用户滚动后保留位置 | 宿主PASS；原房间待用户复测 |
| S3 | 主动发送、回到最新、搜索/引用定位及变高气泡回归 | 最终共享PASS |

发现：RoomPage._changed将任意变动后的最新自发消息交给无条件post-frame jump；未区分历史恢复和主动发送。尚未将此风险当作两种真机症状均已复现。
下一步：建立RED复现，独立检查缓存接续，最小修复后相关门禁及顺序审查。没有新发送真实消息授权，不操作生产。

## 2026-10-21 调查和审查结果

- S1 RED：anchor-red-r2.log，恢复自发旧消息把150px跳到0；RoomPage真实后台更新回归通过。
- S2 RED：cold-red.log，缓存从8条补齐40条后extentBefore仍75px；图片模型几何更新也需保持最新边缘。不能将普通图片解码归为已证实原因。
- 冷缓存策略保持：用户尚在最新边缘时跨同一帧多轮lazy layout跟随；用户已滚动/历史窗口时保留锚点。取消基于旧metrics的方案，其4条历史回归失败留在scroll-green.log；最终scroll-green-r2为15PASS。
- SPEC发现恢复outbox仍选latest；recovery-red-r3两条RED，修复后84PASS。早期夹具编译/未进入older窗口失败不计作RED。
- QUALITY发现视频及消息引用发送漏意图；补充beginLocalSend于异步操作前触发，完成不得覆盖等待期间新手势。direct-red两条引用定位RED，direct-green25PASS。消息/财务调用参数与鉴权未改。
- SPEC及delta SPEC均PASS，独立QUALITY复查中。原全量已主动取消（非PASS）以处理review发现；最终候选将重跑完整门禁。
- 新Debug候选预留0.4.64+2233：所有工作树pubspec最高2232，原emulator-5556包2232、UID10090/首次安装2026-09-26保持。沿用用户此前Debug模拟器交付授权；线上正式版本未变。
- 运行中的资源：root拥有V映射canonical；无服务端操作，无真实消息发送。

## 后续几何与发送定位验收

- 新增 same-ID 新气泡变高 RED（geometry-red.log）；idle 可见中心重定位后保留既有中心，避免连续资料补齐积累漂移。拖动/惯性期间保留原窗口变换路径；geometry-green-r2 13PASS。
- 原启动测试发送后处于最新边缘，却断言任意旧文本坐标不变；重建真实阅读步骤：确认发送到最新，再上滑，固定可见既有中心气泡，SDK接管后边界仍在8px内，同一RoomPage/controller及身份/加密/一次发送断言保留。变高行之间所有文本不可能同时固定；handoff-center-diagnostic记录真实中心cached55与被错误选择的cached58差异。
- 新严格发送边缘断言发现27px布局后续偏移；显式发送意图现在供布局物理持续跟随，各轮lazy extent补算无需父组件重建；用户拖动或程序定位离开最新会同时取消跟随及待执行跳转。未使用会破坏历史定位的old metrics推断。
- SPEC最终PASS（2026-10-21，本轮质量复查待完成）。新媒体独立布局测试、完整启动文件与最终共享门禁仍在进行；编译夹具错误、历史失败和取消记录均保留，不计作通过。
- 发送后历史阅读位置断言完成后，测试显式showLatest再核验canonical-new-head；不能要求保持历史窗口同时强制展示最新头部。

## 全量发现的坐标记账补充

- 第一轮全量在4890PASS/9SKIP/23FAIL（另633 harness）停止修正，非PASS；`origin-accounting-r1-*`保留。23失败中包含旧绝对偏移断言及首个断言失败跳过清理导致的MaintenanceActivity定时器级联，不将它们全部归为产品缺陷。
- 真实补充缺陷：idle可见中心重基准后，页面_lastTimelineScrollOffset仍是旧坐标，下一次真实滚动会误判方向/距离。onOriginRebased仅对坐标补偿同步调整前值；不改变阅读距离，也不对主动非重叠导航使用。
- 惰性布局临时min=-134而原点已校正-1234；仅extentBefore判断会错误清零历史阅读距离。新增实际最新行可见校验，防止临时估计误判。
- `origin-distance-green-r2.log`是真实相对移动RED；`origin-distance-green-r3.log`PASS。`origin-impact-final.log`50PASS：连续历史fling、真实RoomPage恢复、生命周期、变量高度、惯性和定位取消。夹具初次编译错误不计RED。
- 更新夹具为固定可见气泡边界及相对滑动距离；新增用例finally清理。SPEC delta PASS，独立QUALITY复查中，随后重跑最终共享全量。

## 最终共享门禁通过

fb15a9a8冻结输入；2026-10-21 19:51:58–20:03:22+08，6378PASS/9既有SKIP/0FAIL（另893 harness），analyze0/test0/source_stable=true。full-receipt.json/full-summary.json及prior-failure-recheck.json记录最终证据，前次23失败均重跑通过。当前正构建debug-2233-main-fb15，正式2232发布状态未改动。

## 构建环境记录

首次debug-2233-main-fb15在Gradle PreCreateOutputParentsStep/GFileUtils parent-null处失败，尚未完成Flutter源码编译；原日志保留。与历史Windows短盘符构建问题相同堆栈，不能仅凭重跑成功宣称持久根因已修复。未改移动源码，以新run debug-2233-main-fb15-r2重试，源码构建与前后所有tracked mobile blob一致性均通过，固定签名/对齐/包身份已通过，最终语义校验继续。


## 已交付与下一步

2233普通main Debug/x86_64已于2026-10-21 20:13:03+08保数据覆盖安装原5556，固定75b31签名，126163290B/SHA fa8cd9405725fa11933c714daef848e111b7256793f52b8171d71eaaa683f3fe；源码fb15a9a8，设备同字节/UID10090/首次安装保持，真实MAIN/LAUNCHER冷启动PASS。重建全部步骤0。详见[最终报告](../../verification/2026-10-21-timeline-scroll-position.md)。

下一步：用户在原故障房间复测冷启动最新缓存位置，以及连续浏览历史后等待后台接续是否回底。UIAutomator流式层级读取未返回XML，原生群聊滚动未验收，不用宿主或启动成功替代。没有发送真实测试消息，没有修改正式发布配置；不能将本Debug安装称作正式更新已推送。

交付收尾：本任务V映射已移除，构建脚本已移除其Y映射；无本任务遗留测试/打包进程、端口转发或服务端操作。证据cleanup.json，任务/报告/计划和本次current-state段已同步主工作区，历史段原字节保留。
