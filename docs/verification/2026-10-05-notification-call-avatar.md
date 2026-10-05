# 通知与通话头像、摄像头 2203 验证

源码候选 `86772b17b1f2289b315e3c430e46f79043348f6f`，移动tree `c347335af5c38cefe83df8c0da381ea12b3c517a`，版本0.4.34+2203。Android标准重建成品及独立复核通过，19:31保留数据安装模拟器成功；未正式发布。

## 五项实现与证据

1. 已观察且已查看的确切消息ID在Dart及Android原生持久化抑制；返回桌面不再把mounted房间误视为正在查看。延迟旧读确认只取消确切旧提示，执行队列时重新核对，保留真实新提醒。断言涵盖冷进程持久、账号撤销、混合旧读/新pending及排队竞态。
2. App内提醒使用好友/群聊头像；Android系统通知大头像使用本地受限头像字节，失败先保留通用提示，异步静默更新；系统小应用图标仍遵循Android规范。没有把认证头、URL、消息正文加入推送payload。iOS系统通知头像未新增Communication Intent支持，避免无效的二次响铃；App内头像共享可用。
3. Flutter通话返回卡和Android桌面悬浮窗显示头像、等待/持续时长、语音或视频标记，终态清理。
4. 权威联系人identity保存到活动CallState，首次打开、最小化、恢复与重试复用，含本地认证头像请求信息，代际/账号隔离防止串图。
5. 摄像头关闭实际await sender.replaceTrack(null)与track.stop，恢复只采集新video track并接入原sender/stream，音频不重新采集、不改变mic。操作串行、终态与错误状态有断言。既有已验证加密双人通话限制保持，未新增群通话。

## 门禁

- 行为RED/GREEN：n1目录已读、饱和集合、Darwin重复提示、混合新旧、排队取消；n2目录identity/time/camera采集、账号缓存与销毁动作。日志保留真实失败及后续修正。
- 最终原生59PASS/0FAIL/0skip，`:app:testStandardDebugUnitTest --no-daemon` exit0，native-final-2.log及不可变XML。首次59/1失败为通话测试仅预期incomingCall，修正后仍精确验证合法UI metadata事件与无动作重放；不是删除失败断言。
- 静态分析No issues found，exit0；首次18issues保留，修复mounted、公有头像API、括号/import。测试夹具后最终analyze-final-3.log35.4s exit0 No issues。
- Python相关14PASS；frontend526PASS，UI契约34组件/535屏PASS。HTML demo/CUA合成状态camera off/minimize/restore确认，不代替真实设备/通话。
- Flutter完整回归第二轮正确S短目录+冻结Olm/SQLCipher运行库5482PASS/9skip/0FAIL exit0，5:31；首次长目录/缺DLL环境与两个夹具失败已保留并终止exit1，不称PASS。
- verify.ps1预检缺.env/local.env，未执行。不导入生产秘密；未宣称整库verify通过。

## 原生/设备与启动边界

[同源iOS CI37301710017](https://github.com/SuperJJ2333/StarChat/actions/runs/37301710017)检查完整生产原生编译及iOS18/26保留数据库/Keychain连续性；完整生产编译SUCCESS，iOS18/26原生步骤已于19:43:07整体SUCCESS，未签名/分发。Android模拟器已0.4.34+2203，install-r保留UID10090/首次安装时间，实际base.apk SHA一致。真实账号提醒头像与双设备视频关闭/开启、声学表现仍需实机复测。

Android MainActivity singleTask、通知intent CLEAR_TOP/SINGLE_TOP和onNewIntent复用；通知点击并不强制冷启动。进程/页面均存活为hot，页面重建但进程存活为warm，进程已消失为cold。后台无固定统一时限，系统回收策略决定。参见[Android官方启动分类](https://developer.android.com/topic/performance/issues/launch-time)。本次没有对用户真实设备的后台驻留时间作实测。

## 决策与成本

Ruling: opaque hash未知push没有可证明的事件顺序；已读房间先显示quiet pending，Matrix确认旧读取消、确认新消息提醒一次。完全挂起且无法sync时托盘仍可能保留静默待确认项；不声称所有未知旧事件零托盘，也不以全部房间静音损失新提醒。

计时、授权、下一可执行步骤见[任务台账](../workflow/tasks/2026-10-05-notification-call-avatar.md)。主区1372无关WIP已再次hash验证保全，后续集成必须保持原字节。

## Android成品

19:21–19:24:38标准x86_64 debug重建结束，source APK128528548bytes/源SHA a8133069…66edca；成品122192594bytes/SHA `64d4341198cc9e66d5dea05af8ebd1eb43cd17a3bb9582717160a8979d6bcb08`。固定签名 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，v2/v3及alignment、清单/资源/DEX语义、Flutter资产/原生库逐项、冷锁屏门禁通过，sourcefreeze前后同1880文件。首次source build68.2s通过，无注册器重试。KGP未来版本/Gradle弃用与未改Robolectric旧flag警告属于既有插件工具链，未忽略当前analyzer错误。

APK位于 `docs/verification/artifacts/2026-10-05/notification-call-avatar/delivery/ChatFlow-0.4.34-build2203-x86_64-debug-rebuilt.apk`，复制到主区后SHA一致；这是模拟器debug包，不是ARM64正式发布包。独立成品审查通过；19:31:04 install-r成功、SHA读回一致，LauncherStatusok，19:34同PID15936持续160.57秒、matching Java fatal0（仅启动smoke）。

## 最终平台结果与下一步

iOS CI37301710017 19:43:07整体SUCCESS，三个job均成功；已读取实际18/26日志：各seed23PASS/new-process verify4PASS，Retained seed database exists True；完整生产编译首轮成功。Windows final-gates.json及源/包freeze绑定源86772b17，后续文档commit不改变移动tree c347335a，复用同输入已验门禁。

N1/N2/N3有序规格→质量及独立成品审查均接受，无P0–P2；五项实现与模拟器交付技术完成。真实提醒/头像、视频停止与恢复、声学和iPhone覆盖安装仍待用户，不承诺永不出现L04/L07；本轮未改消息密钥加载，不作额外密钥迁移。正式更新弹窗/ARM64发行/企业IPA未发布。源码集成回执见本任务artifacts/main-integration.json。

耗时已知区间：19:13–19:19正确环境全量5:31，最终analyze35.4s；19:21–19:24:38源码/标准重建约3分38秒（source68.2s）；19:31 install-r/启动，19:34 smoke160.57秒；iOS19:14:55–19:43:07约28分12秒，与本地步骤并行，不能相加。18:08起本轮root恢复/审查/返工/归档区间有台账；更早实现主动时长未捕获，不能按mtime猜工时。

19:48实际main快进集成完成（ebcf09fa文档候选），移动tree c347335a未变；1372无关WIP SHA及原current-state正文保全，index空，自己的临时stash已drop。最终文档commit/远端读回记于main-integration.json。继承的managed worktree与buildcache保留；本轮没有生产服务变更。
