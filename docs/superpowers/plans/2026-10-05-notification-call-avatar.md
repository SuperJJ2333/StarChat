# 通知与通话头像、摄像头 Implementation Plan

> **For agentic workers:** Use subagent-driven-development for separate notification/call implementation and ordered independent review. Human approved the bounded in-chat design and explicitly requested implementation on 2026-10-05.

**Goal:** 五项用户需求：不重放已查看的旧消息提醒；提醒显示会话头像；通话悬浮窗头像+时长+媒体图标；通话恢复头像连续；视频摄像头关闭/开启实际停止/恢复发送。

**Architecture:** 沿既有设备端Matrix通知策略与持久原生claim抑制已读事件，保留退出后新消息提醒。通话identity和camera状态归CallController/backend，页面和Android悬浮窗消费同一活动会话信息。原生仅接收本地展示头像字节，不把头像URL/认证头放入推送payload。

**Tech Stack:** Flutter/Dart、Android Kotlin、既有Matrix/WebRTC适配器、HTML demo。

**Spec:** 用户本会话五项需求与已确认方案；docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md；docs/runbooks/mobile-delivery-workflow.md；docs/runbooks/ui-development.md。

## Global Constraints

- 不复制主区1372无关WIP；复用干净managed worktree，基线4c8c16c7。
- 不变更E2EE/账号密钥、业务API或金融边界；既有通话仅已验证加密双人会话，不新增群通话功能。群头像需求适用于现有会话展示，不能通过本任务绕过双人通话安全限制。
- 用户已明确摄像头按钮为停止/恢复本人视频发送，音频继续。失败保留实际状态并可重试；离页恢复不自动打开摄像头。
- 本轮修改/验证与保留数据模拟器交付获授权；正式发布/弹窗不因上一任务发布授权自动推断。
- build需冻结前确认线上/CI占用；暂不提前修改版本。

## Review Focus

- 开房间→查看→退桌面，延迟push/sync旧事件禁止重放；退出后真实新事件仍通知。
- 账号切换、异步头像加载与通话结束/新通话代际不可串图或泄漏授权头。
- Matrix认证头像与业务HTTP头像两条链路；失败回退，头像加载不阻塞通知/接听。
- camera快速点击/异步失败/离页恢复/终态防止错误翻转；不干扰mic/音频。
- 未接通悬浮窗显示等待，接通持续时长不随最小化重置；结束清理timer/头像。

## Task N1 通知已读抑制与头像

Owned: lib/core/notification/* affected classes、lib/features/matrix/matrix_notification_event_source.dart、conversation_read_state.dart、lib/ui/notification/in_app_banner_overlay.dart、Android push/NativeMessageNotifications.kt及对应focused tests。禁止编辑app_home.dart、MainActivity.kt、call files、registry/frontend。

- [ ] 写并运行旧已读事件后台重放、真实新事件、账号隔离及私聊/群头像失败RED。
- [ ] 沿原生claim/读状态追根因，最小抑制；头像经本地解析与缓存传入现有presenter和banner。
- [ ] focused GREEN及实际native相关门禁；记录命令/退出码，不并发Flutter。
- [ ] 规格符合性审查→质量审查，修复阻断项。

## Task N2 通话身份、悬浮窗与摄像头

Owned: call_controller.dart/call_page.dart/call_ui_manager.dart/matrix_call_adapter.dart/native_call_coordinator.dart/call_notifications.dart、app_home.dart限定call入口、Android call/*、MainActivity.kt限定call桥接及对应focused tests。禁止编辑notification/push、registry/frontend。

- [ ] 写并运行主叫最小化再恢复头像、悬浮窗持续时长/媒体类型、camera停止/恢复/失败/终态RED。
- [ ] 将权威identity保存至活动state，页面恢复复用；摄像头调用公开backend接口，真实track控制与状态保持。
- [ ] Android桌面悬浮窗消费本地头像+连接时间/媒体类型；Flutter悬浮窗同义；安全失败、终态清理。
- [ ] focused GREEN、native编译及有序双审。

## Task N3 Demo/注册与整体交付（root）

Owned: packages/ui-contracts/changliao-component-registry.json、frontend/src/screens/calls.js及相关通知demo/目录/tests，task/plan/current-state/report。

- [ ] 注册状态/props/tokens并更新HTML demo，保留实际摄像头开关交互、悬浮窗、通知头像展示。
- [ ] demo RED/GREEN、UI contract、frontend、最终Flutter analyze/全量及平台相关门禁。verify环境预检，不引入生产secret。
- [ ] broad独立规格→质量审查，版本冻结后标准Android rebuild/固定签名、保留数据安装模拟器；iOS相关原生CI验证。
- [ ] 证据身份/计时与当前状态更新；逐文件保护1372WIP，必要源码集成按已授权会话上下文。
