# Android2225 表情面板修复与冷启动问题调查

普通 **0.4.56（2225）Debug** 已保留数据安装到 emulator-5556。本包仅修复最近表情的位置稳定性。冷启动已经复现“缓存准入拒绝后，打开页面前等待本地时间线”的慢路径，尚未修复；尚不能认定它解释用户所有房间的每次等待。本任务未改动正式渠道。

## 表情修复

原来每次选择都立即 setState 重排 _recents，下一次同位置点击可能选到另一个表情。现在本次展开保持快照；使用记录仍立即进入既有串行持久化队列，下次展开读取最新顺序。首次选择后迟到的初始加载也不能再插入行或移动位置。换账号清空旧展示并丢弃旧异步结果。

RED 用真实坐标断言复现首两格互换；最终受影响5文件39PASS，完整analyze0/17.4s，独立SPEC→QUALITY/security通过。held-preferences测试在任何断言前注册清理，释放gate/卸载/排空队列/恢复mock。未变启动/E2EE/native模块沿用2224同源覆盖；原全量6204PASS/9SKIP/2ERROR及修正记录、旧metrics FakeTimer失败仍在原任务，不声称新全量命令全绿。聚合verify缺.env未执行，未导入生产凭据。

新包模拟器验证见emoji-device/receipt.json：同位置连续选择的输入结果、当前展开不重排、重开后顺序更新、无实际发送及草稿恢复均逐项记录。首轮UI脚本误将非clickable语义标签当点击节点，尚未输入即停止；保留observe-r1-failure，改为使用当前UI里同bounds的真实clickable子节点后通过，未改产品。

## 冷启动入房：已复现慢路径，修复仍开放

用户确认包括测试群在内所有房间都会等待。已装2224只读冷启五轮均cacheHIT，回调内部入房330/409/449/529/532ms，不能用这些数据否定用户感知。业务trace在点击回调进入后才开始，第一帧回调也不等于屏幕像素已经呈现。

无主机测试同时运行的r5，在第一份缓存内容frame日志后请求点击；截图00仍黑屏、01列表、02已出现缓存气泡/输入框。截图02采集区间为请求点击后1359～1906ms，只能界定一次观察，不是精确present时间。r1/r4有主机测试重叠，不用于受控性能对比。CPU service追加读取不可用，未当作证据。

2225另一次启动观察同为HIT、回调内部430ms，截图01仍列表、02已有真实缓存气泡，后者采集区间为请求点击后1828～2359ms。该轮显式打开启动profiling extra，CPU service仍不可用，不能将它当稳定性能基线；ADB命令/截图开销也不能算成纯APP响应。最终已另行恢复不带profiling extra的普通main入口，原空草稿仍保留。以上新观察进一步限定验收边界，不证明延迟根因。

代码和独立只读复核确认：有效缓存走openRoomLease快入口，绕过SDK完整恢复；未发现trace之前固定2～3秒await。但房间缓存缺失/失效时，openRoomTimeline→_withLeaseOperation→_withClient仍可能await initializationCompleted，PreparedRoomPageEntry完成后才push。列表缓存存在不保证该时刻每房间头均有效；普通状态/隐私代际变化可使旧头失效。尚无证据证明所有等待都来自该分支或哈希。

下一项需要补齐“原生触摸时间→Dart回调→导航→实际呈现”的关联，以及点击当刻房间缓存有效/失效原因的闭集计数；不应再仅凭业务回调内部trace宣告即时入房已验收。本次无启动/导航/认证逻辑变更。

最后无并行构建/测试、无profiling extra的2225复测 installed-2225-cold-sdk-clean **复现慢路径**：cacheAdmissionMiss/admissionRejected，完整身份检查在Dart入口3870ms结束、SDK在6064ms就绪，随后才发起点击。业务回调后的房间租约在11ms完成，但route_push_started到1446ms才出现，两者间1435ms覆盖PreparedRoomPageEntry.prepare的本地时间线准备及其调度等待；content_ready1817ms。该区间不是已独立测量的SQL纯执行时间。trace总4886ms还包括内容显示后的远端同步，不能把4886ms称为入房首屏时间。

因此，这轮延迟发生时身份/SDK已经恢复，仍有“先完整准备本地时间线，再push页面”的实现门槛。快照有效时可以直接进入；本轮快照准入被拒，走了慢路径。还需细分admissionRejected原因，不能仅凭该枚举断言是普通同步、隐私变更或密钥问题。这提供了一条已定位的慢路径，未改其行为，也未证明所有房间每次延迟同因。

## 身份检查为何耗时

这是本地SDK开库写入前的账号/设备/Olm身份与数据库一致性预检，不是每次联网重新登录。完整预检防止错误账号/数据库或丢失身份时SDK继续写入、错误新建身份；缓存显示使用独立的最小账号/密钥/代际绑定和认证加密校验。

2.21～2.68秒不是显示缓存必须付出的业务成本。旧三轮细分：最大文件复制并哈希约751～879ms，快照哈希461～575ms，原文件最终复核450～842ms；SQL身份读取116～164ms，指纹7～12ms。它们是逐文件样本区间，不能相加当完整阶段总时长或总分位数。主要成本是DB/WAL/SHM的大文件I/O和哈希；完整文件读预算虽从4遍降3遍，仍随历史体积/磁盘/负载变化。

当前后台恢复是未等待的Future，并非独立CPU隔离线程，SHA计算仍在调用isolate。此源码事实说明潜在竞争，不能单凭它确定用户输入延迟的因果。快照显示应只受最小准入检查约束；完整预检及SDK恢复应继续后台工作，不能把其耗时当强制禁止入房的理由。

## 交付与构建身份

源码84152b0f205dc8b44506a6dbdf1881dbc9913734；APK SHA256 `e992a25726f3849c9f0662632caadeb9df2b14df016ac91bd3206311815e9ba8`，126114138字节，签名`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。源码构建→Apktool2.12.1重建DEX/资源/清单→align36-P16→固定签名→重解包语义/资产/库/包名/版本/ABI验证全部通过。编译前后2141 tracked mobile blobs核对Git，实际字节manifest一致；不宣称生成缓存/工具链输入闭合可复现。

首次完整构建source-build报Gradle parent空指针，未签名或安装；诊断首命令因PowerShell参数解析得到额外.dart任务，保留失败；修正参数数组后单任务通过，最终相同冻结源码完整r2重新通过所有门禁。未用诊断产物交付，也未确定首空指针的持久根因。原有KGP迁移提示与2224构建相同，不在本表情修复中迁移依赖。

最终设备APK哈希一致，UID10090、首次安装2026-09-26 04:06:20保留；install-r，无卸载/清数据/降级。未发送真实测试消息。原始证据位于`C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat/docs/verification/artifacts/2026-10-18/emoji-cold-entry`，见[任务](../workflow/tasks/2026-10-18-emoji-stable-recents-cold-entry.md)和[计划](../superpowers/plans/2026-10-18-emoji-stable-recents-cold-entry.md)。
