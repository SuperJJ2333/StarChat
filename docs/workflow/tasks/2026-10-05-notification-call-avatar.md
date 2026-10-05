# 通知与通话头像/摄像头跟进

用户五项需求已确认方案，并于本轮“好的，请你开始修改”明确授权；摄像头含义已确认：关闭/开启本人的摄像头，停止/恢复向对方发送画面。

[计划](../../superpowers/plans/2026-10-05-notification-call-avatar.md)。基线4c8c16c7；干净managed worktree codex/notification-call-avatar-2203。前序2202已正式Android发布及iOS原包交接，本任务新修复尚未包含于2202，不提前宣布发布。

| ID | 验收 | 当前 |
| --- | --- | --- |
| N1 | 查看会话后桌面不重放旧提醒；新提醒与帐号隔离；消息头像 | RED/GREEN、原生31通知/最终全量PASS；有序审查接受 |
| N2 | 通话头像连续、悬浮窗头像+时长+语音/视频、摄像头真实开关 | 身份/camera/缓存/终态专项及整体PASS；有序审查接受 |
| N3 | 注册/demo/最终两端验证及模拟器 | 526 frontend/34组件535屏 PASS；有序审查接受；整体平台门禁待执行 |

根因证据：app_home.dart主叫首次CallPage传authoritative.avatarUrl，但CallController.start没有identity；CallUiManager恢复page读state.identity因此回退。banner coordinator明确avatarUrl:null、overlay仅Placeholder；Android CallOverlayService明确applicationInfo.icon，无时长。旧提醒后台重放仍需focused/native证据定因。

启动问答：Android MainActivity singleTask、通知intent CLEAR_TOP|SINGLE_TOP和onNewIntent复用，通知入口不会强制冷启动。进程/页面是否被系统销毁决定cold/warm/hot，后台无固定统一超时。仅源码行为说明，不声称具体用户设备进程已测。

阶段开始：2026-10-05本轮恢复与只读定位；主动时长未捕获。原有主区WIP保持。下一步N1/N2先失败用例，root注册及HTML demo。Temporary evidence仅docs/verification/artifacts/2026-10-05/notification-call-avatar。

## 2026-10-05 18:11 +08 阶段恢复

源仍在338ff007 planning HEAD的未提交任务工作区，版本尚2202。N1先40专项PASS，审查R1后台mounted房间误视为正在查看、R2饱和集合成员变化漏传播、R3Darwin头像二次响铃；R2/R3有实际RED→136 GREEN及有序审查关闭。R1第二轮23 GREEN，审查又发现串行队列里的延迟旧读取消可能在新提醒展示后执行；第三轮仅修正执行时事件检查并补回归。Native最终门禁尚未运行。N2 72 Flutter/4 Python PASS，已实际覆盖sender detach+track.stop停止采集、新video-only track恢复及音频保全；账号cache scope与disposed native action guard补测中。

N3独立规格→质量审查接受，526 frontend、34组件535屏契约PASS；CUA合成页面camera off/minimize/restore自定义头像与off状态已观察，非真实通话。verify.ps1预检缺.env/local.env，未执行；不导入生产秘密。过去native attempts flavor歧义及未完成UI token编译错误已保留，待最终统一标准flavor门禁。

Ruling: 仅包含opaque hash且尚未Matrix确认的旧读房间push显示quiet pending，确认旧读取消、确认新事件升级提醒一次 — 无排序信息不能可靠判断未知事件 — 错误成本为完全挂起且无sync时托盘仍可能有静默待确认项；不误静音真正新事件，不增加服务端明文。

时间：本轮恢复18:08–18:11工具/审查协调；更早精确主动时长未知。下一步完成两项边界专项与有序review，冻结源码后一次统一analyze/Flutter全量/native Gradle，再版本/构建及保留数据模拟器交付。未正式发布。

## 2026-10-05 18:40 +08 最终候选验证

N1 R1排队竞态actual RED cancel2vs1→coordinator24PASS，后有序独立审查R1/R2/R3全部关闭，N1/N2/N3及combined源码SPEC→QUALITY ACCEPT。N2销毁回调30PASS，账号cache隔离5PASS（都有真实RED）。

最终原生第一次实际运行 :app:testStandardDebugUnitTest exit1：59测试/1FAIL，通知31项全PASS；通话旧测试只期望incomingCall，新增合法presentationUpdated多一个。仅测试改为精确两个UI事件，仍验证ringing/callId/retry且新增不发送bridge action、callerName/connectedAt断言；没有改生产native行为。root最初重定向使用错误父路径，命令未执行且无日志，不能作为原生门禁；随后以绝对路径执行并保留真正失败日志。

最终analyze首轮exit1/18issues，最小修复花括号/无用imports、async mounted guard、公有AvatarCacheImageProvider替代测试专属buildProvider；第二轮18:40 exit0 No issues found，11.5s。Python相关14PASS exit0；前端526/契约34/535输入未变复用。全库verify仍缺env未执行。

18:38线上只读确认Android2202/iOS2194，18:30 CI最近20run无新版本占用；bump入口已成对改为0.4.34+2203并3版本契约PASS。当前只是候选版本，未构建/安装/正式发布。下一步最终原生第二轮、共享全量，再冻结commit/CI和APK标准重建。

## 2026-10-05 19:02 +08 全量环境返工

最终原生第二轮exit0，59/59无skip；日志native-final-2.log、不可变XML与native-final-summary.json。完整Flutter第一轮在长实际路径运行且遗漏已知Olm DLL PATH：至少43失败，含Windows长路径数据库/媒体错误、四类Olm setup错误，以及call_entry_identity旧源断言和native_call_coordinator元数据fixture触发未初始化binding。18:59按确切本任务flutter test进程59364及子进程终止（已验命令），exit1，不能算完整PASS。根执行器漏用了已存在的短S路径与运行库，已承认并修正，无生产代码为环境绕过。

19:01短S cwd确认、Olm/SQLCipher DLL实际加载与SHA冻结通过；两个通话fixture最小修正由N2执行。下一次全量使用S:/apps/mobile_flutter与冻结DLL PATH，保留旧失败日志。若平台/源变化才扩门禁，不重复前端等价证据。

## 2026-10-05 19:21 +08 源冻结与构建

测试夹具33专项GREEN后提交候选86772b17（47明确任务文件），移动tree c347335a。第二次完整Flutter正确S路径/DLL环境5482PASS/9skip/0FAIL exit0，5:31；最终analyze35.4s No issues exit0，正常pubget exit0且lock不变。Native59PASS、Python14/前端526/34组件535屏复用等价输入，有序review全接受。

19:14无签名iOS workflow_dispatch run37301710017 exact86772b17，三个相关原生job进行中。19:20再次线上只读Android2202/iOS2194；冻结1880移动源文件及生成输入，manifestSHA d1c17050dcde5b8ef398c4267ad0dd4618d3b80e1d3609c38d779ba10e92b0e8。19:21 build driver preflight PASS，标准debug x64 source→Apktool2.12.1→zipalign36→现有75b31签名重建开始。未安装/正式发布；HEAD构建期间保持86772b17，不因证据文档改变source identity。

## 2026-10-05 19:31 +08 模拟器交付

19:28独立成品审查接受：实际apksigner/zipalign/aapt及SHA/122192594bytes/27353类/26DEX/474资源/原生资产/lock/1880源一致。19:31:04以adb install-r覆盖emulator-5556成功，UID10090/首次2026-09-26 04:06:20保留；读回0.4.34+2203及实际base.apk SHA64d43411…6bcb08。Launcher Statusok，PID15936，短时观察进行中。未卸载、未清数据、没有给真实用户发送测试消息/发起通话；用户五项真实场景待复测。

同源iOS完整生产编译已SUCCESS，18/26正在Native media/seed encrypted history，尚未整体PASS。正式生产仍Android2202/iOS2194，未正式发布本轮更新弹窗。下一步完成模拟器两分钟PID/crash观察、iOS保留数据步骤与记录，再只集成本任务源码及文档并保全WIP。

19:34启动smoke终验：同PID15936持续160.57秒、matching Java fatal0；仅启动观察，不冒充真实消息/媒体/声学验证。iOS18已进入新app进程保留历史验证；iOS26仍native seed步骤。当前只等待其本任务相关门禁，不重复本地已通过源测试。

## 2026-10-05 19:45 +08 两端技术完成

iOS37301710017 exact86772b17 19:43:07全run/3job SUCCESS。18/26实际日志各seed23PASS及新app process verify4PASS/Retained seed database exists True；无签名生产分发。最终技术验收N1/N2/N3完成，用户实际五项交互复测待办；下一步执行明确owned-source47加本任务docs的main快进集成/远端读回，1372WIP SHA与原current-state正文保全，不将它们纳入commit。正式移动发布仍另授权，不再重做同输入长门禁。
