# 通知与通话头像/摄像头跟进

用户五项需求已确认方案，并于本轮“好的，请你开始修改”明确授权；摄像头含义已确认：关闭/开启本人的摄像头，停止/恢复向对方发送画面。

[计划](../../superpowers/plans/2026-10-05-notification-call-avatar.md)。基线4c8c16c7；干净managed worktree codex/notification-call-avatar-2203。前序2202已正式Android发布及iOS原包交接，本任务新修复尚未包含于2202，不提前宣布发布。

| ID | 验收 | 当前 |
| --- | --- | --- |
| N1 | 查看会话后桌面不重放旧提醒；新提醒与帐号隔离；消息头像 | 定位，准备RED |
| N2 | 通话头像连续、悬浮窗头像+时长+语音/视频、摄像头真实开关 | 主叫start未保存identity已确认；准备RED |
| N3 | 注册/demo/最终两端验证及模拟器 | 待实现 |

根因证据：app_home.dart主叫首次CallPage传authoritative.avatarUrl，但CallController.start没有identity；CallUiManager恢复page读state.identity因此回退。banner coordinator明确avatarUrl:null、overlay仅Placeholder；Android CallOverlayService明确applicationInfo.icon，无时长。旧提醒后台重放仍需focused/native证据定因。

启动问答：Android MainActivity singleTask、通知intent CLEAR_TOP|SINGLE_TOP和onNewIntent复用，通知入口不会强制冷启动。进程/页面是否被系统销毁决定cold/warm/hot，后台无固定统一超时。仅源码行为说明，不声称具体用户设备进程已测。

阶段开始：2026-10-05本轮恢复与只读定位；主动时长未捕获。原有主区WIP保持。下一步N1/N2先失败用例，root注册及HTML demo。Temporary evidence仅docs/verification/artifacts/2026-10-05/notification-call-avatar。
