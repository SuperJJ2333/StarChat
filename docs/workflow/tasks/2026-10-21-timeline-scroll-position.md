# Android2232聊天滚动定位回归

- 用户2026-10-21反馈：上滑历史被拉回最新；冷启动入房停在旧图片而非缓存最新消息。授权排查及修复，沿用已批准interactive-cache-startup计划的滚动保持契约；本次不自动发布正式更新。
- 基线：interactive-cache-startup工作树，1036a81e，开始时干净。线上2232不包含本次后续修改。
- 开始调查：2026-10-21 18:45–18:50+08，精确起点未知。root独占生产文件与测试；独立审查只读。
- 所有权：room_page.dart、room_timeline_controller.dart、latest_message_anchor.dart、timeline_scroll_anchor.dart及匹配测试、本记录/计划/报告/本任务证据。
- 计划：[回归修复](../../superpowers/plans/2026-10-21-timeline-scroll-position.md)。

| ID | 验收 | 状态 |
| --- | --- | --- |
| S1 | 历史浏览期间补消息/回执/分页不强制回最新 | 调查 |
| S2 | 普通冷入房显示最新缓存，补齐不落在旧图片；用户滚动后保留位置 | 调查 |
| S3 | 主动发送、回到最新、搜索/引用定位及变高气泡回归 | 待测 |

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
