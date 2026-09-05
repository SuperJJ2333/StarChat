# 2026-09-05 图片选择视频加载 + 语音/视频来电全链路修复

**任务范围：** 直接修改本地工作区，完整修复"图片页面的视频加载"与"语音/视频来电展示、接听及恢复"两条流程；保留既有未提交改动；不 pull、不重置、不部署、不发布。

**基线：** 提交 `35cd07e`（feat(calls): Telecom-based system incoming call architecture）之上的本地工作区（含用户 WIP 改动，全部保留未动）。

---

## 一、问题根因与修复明细

### 1. 相册：查询缓存混用（common/video）

**根因（已实证）：** `GalleryAccessCache` 只有一个 `_recentAlbum` 桶，而"最近图片"（RequestType.common）与"本地视频"（RequestType.video）都是 `entity == null` 的虚拟相册，`DeviceGalleryPager.ensureAccess()` 对二者都会走 `recentAlbum()` 缓存——先打开"最近图片"再切"本地视频"会直接复用 common 相册定位结果，绕过视频查询。

**修复（`apps/mobile_flutter/lib/features/matrix/device_gallery_source.dart`）：**
- `GalleryAccessCache._recentAlbumsByType: Map<RequestType, AssetPathEntity?>` 按 RequestType 分桶；`recentAlbum(type, load)` 按 type 存取（`device_gallery_source.dart:166`）。
- 权限范围指纹：`ensurePermission(request, {scope})` 缓存 `'full'/'limited'`；`invalidateIfScopeChanged` 在范围变化（部分授权 ↔ 全部照片 ↔ 撤销）时整体失效——有限授权不再被当作完整媒体库访问。
- `DeviceGallerySource.permissionScopeChanged()`：页面 resume 时用 `PhotoManager.getPermissionState`（只查询不弹窗）探测范围变化。
- 调用链完整覆盖：页面选择 → `pagerFor(album)`（透传 `requestTypeForAlbum`）→ `ensureAccess()`（按 `_type` 分桶定位）→ `getAssetListRange` 分页读取 → `loadNextPage`。
- 缓存失效时机（三种）：① 权限范围变化（resume 探测）；② 系统媒体库变化（选图页挂载期间 `PhotoManager.addChangeCallback` + `startChangeNotify`，变化即 invalidate + 重载当前相册）；③ 会话结束（进程内存态，应用退出即丢；外部变化重载路径 `_reloadAfterExternalChange`）。

### 2. 相册：快速切换时旧请求覆盖新结果

**根因：** `_ImagePickerPageState._load/_loadMore` 无请求批次概念；切相册后旧分页器的在途结果回来会 `setState` 覆盖新相册的列表/加载态/错误态（`photos = [...photos, ...next]` 还会把旧相册数据混入新列表）。

**修复（`apps/mobile_flutter/lib/features/matrix/image_picker_page.dart`）：**
- 请求批次 `_loadEpoch`：每次 `_load` 递增并捕获；相册切换产生新批次。在途请求完成后 `epoch != _loadEpoch` 即丢弃（不 setState）。
- `_loadMore` 同时校验 epoch 与分页器实例（`identical(activePager, pager)`），旧分页器的追加页不混入新列表。
- 分页与首屏优先保留：首屏 12 张、滚动预取 20/页、缩略图有界并发解码全部未动。

### 3. 相册：视频封面（首帧）失败无重试、并发无节制、缓存损坏不失效

**根因：** `loadVideoFirstFrame` 只尝试 200ms 单点抽帧；`_memoizedFirstFrame` 把失败（null）的 Future 永久 memoize——同一视频条目之后一直显示占位；每个格子各自直调 `VideoCompress.getByteThumbnail`，快速滚动瞬时堆积解码任务；空缓存文件被当命中返回。

**修复：**
- **多点位采样**：`samplePositionsFor(duration)` 按时长从 `[200,500,1000,2000]ms` 选合法点位（留 50ms 余量；短视频回退中点）；`loadVideoFirstFrame` 复用 `extractVideoPoster`（多时间点 + 近黑帧跳过，亮度 <16 跳过）。
- **全局协调器 `VideoFirstFrameStore`**（`device_gallery_source.dart`）：
  - 有界并发：底层解码同时最多 2 个（`maxConcurrent`），其余 FIFO 排队；
  - 并发合并：同一资源并发请求共享同一 in-flight Future（测试实证 3 并发 → 1 次抽帧）；
  - 成功缓存：内存 memoize，重复请求零成本；失败**不缓存**；
  - 失败退避重试：`maxAttempts=3`、`retryBackoff=2s×次数`——退避窗口内的调用快速返回 null 且不提交解码任务（不会"每次 build 都重试"）；预算耗尽后 `retriesExhaustedById` 为真，`resetById` 提供手动重试入口；
  - 超时按失败记账（默认 10s）：原生任务悬挂不再无限等待；预算上限约束每资源最多提交 3 次原生任务（不会"释放计数后继续无限提交"）；
  - 磁盘缓存键 `sha256(path|id|durationMs|size)` 反映资源更新；空/损坏缓存文件删除后重新抽帧。
- **UI（`image_picker_page.dart` `_VideoFirstFrameCell`）**：逐格懒加载保留（整页展示不等解码）；失败占位明确（灰底摄像机图标）；完成后提供重试按钮（`image-picker-frame-retry-<id>`）；封面失败不删条目、不阻断选择/预览/发送（预览页 `gallery_video_preview.dart` 已有"准备失败可重试/仅选择发送"降级，未改动）。不承诺所有容器可解码：失败状态即为上述占位 + 重试。

### 4. 通话：来电自动接听（最高优先级）

**根因（已实证，`app_home.dart` initState）：** `native_call` 通道处理器中 `case 'incomingCall': case 'callAccepted':` 共用分支——收到**任何**来电事件（推送唤醒、Telecom 状态广播）就可能 `calls.accept()`；`_autoAcceptWhenRinging()` 实现"未来 8 秒内出现任何 ringing 就接听"的宽泛等待。原生层推送唤醒（PushEventDispatcher → CallManager.onIncoming → emit incomingCall）一到即触发接听链路。

**修复：**
- **严格事件区分（新文件 `lib/features/matrix/native_call_coordinator.dart`）**：
  - `incomingCall`：仅 `arbiter.registerIncoming` + 呈现来电页，**绝不接听**；
  - `callAccepted`：用户明确接听（通知[接听]/CallActivity[接听]/Telecom onAnswer/冷启动重放）→ 仅当 Matrix 已响铃（phase==ringing）时执行一次 `accept()`（权限不足拒接、会话失效转 failed 由 CallController 内建）；
  - `callRejected`：用户明确拒绝 → 仅响铃时 `reject()`；
  - `callEnded`：原生呈现结束（60s 超时/远端取消）→ 按相位收尾（connected/connecting→hangup；ringing→reject）；
  - 接听/接听处理中/媒体连接成功/拒绝/结束五态互斥：`requestingPermission/connecting/connected` 相位下重复接听事件只恢复呈现。
- **删除 `_autoAcceptWhenRinging`**，替换为绑定式待接听仲裁器 `NativeCallArbiter`：
  - 请求绑定原生 callId；期限 15s；取消条件：对应原生通话 `callEnded`、Matrix 通话 ended/failed、**新通话（不同 callId）呈现**、会话 dispose（登出）——过期或被取消的请求绝不应用到下一通电话（均有测试断言）。
  - "推送先于 Matrix 同步"场景：用户在原生通知点[接听]而 phase 仍 idle → 登记；Matrix 响铃事件到达（controller notify）→ 消费待接听 → microtask 里 `accept()` 恰好一次。
- **去重**：`_accepting` 执行锁 + 相位守卫：重复事件/双通道/连点不产生第二次 accept（测试实证 3 次 callAccepted → 1 次 accept）。
- **类型以同步结果为准**：Dart 侧来电类型来自 `CallBackendEvent.incoming(type:)`（Matrix `m.call.invite` 实际值）；原生层 `video=false` 仅为唤醒呈现初始值，`reportCallState` 同步真实类型（见下）。

### 5. 通话：桥接初始化与冷启动动作交接

**根因（已实证，`MainActivity.kt`）：** `NativeCallBridge.setCallHandler(...)` 在 `native_call` 通道创建**之前**调用（此时 `channel == null`，`channel?.setMethodCallHandler` 是空操作）→ `answerCall/rejectCall/endCall/getActiveCall` 全部不可达；`NativeCallBridge.setUp` 每次 `addListener` 而 `teardown` 不移除（重建泄漏）；`CallBridge.invoke` 在引擎未起时只 `launchApp`，用户动作丢失。

**修复：**
- **初始化顺序（`MainActivity.kt`）**：`NativeCallBridge.setUp(messenger, CallHandlers(...))` 一次完成"创建通道 + 注册方法处理器 + 订阅 CallManager 事件"；`CallBridge.setUp`（chatflow/call，仅 dismiss）随后；`cleanUpFlutterEngine` 中两者 teardown（幂等：setUp 先 teardown 再注册；监听器持有引用可移除）。
- **Flutter ready 握手**：Dart `NativeCallCoordinator.restorePendingState()` 在 AppHome initState 调 `ready` → 原生标记 `flutterReady=true` 并返回 `{actions, activeCall}`。通道对象存在 ≠ 业务就绪：`notifyUserAction` 在未就绪时**暂存动作并拉起应用**，不伪造接听、不丢失动作。
- **待处理动作暂存（新文件 `android .../call/PendingCallActions.kt`）**：只存 `callId/action('answer'|'reject')/时间/消费状态`（无敏感明文）；`drain` 取出即标记消费（一次动作只重放一次）；超龄 30s 丢弃；同通话同类动作去重；容量上限 8。Dart 侧 `_applyPendingActions` 对超龄动作二次校验后丢弃。
- **冷启动顺序**：AppHome（登录会话根，账号已恢复）→ ready 握手取回动作 → `getActiveCall` 权威查询 → 匹配处理（answer 走 `_answerFromUser`，reject 走 `rejectFromUser`）→ Matrix 同步恢复真实通话后消费待接听。接听与拒绝都覆盖。
- **getActiveCall 有真实业务调用方**：`NativeCallCoordinator.restorePendingState()`（测试断言 `getActiveCall` 必被调用）。
- 原生用户点[接听]时：`CallManager.onAnswerRequested()`（状态 ringing→answering）+ `NativeCallBridge.notifyUserAction` → Flutter 决定实际接听；CallActivity/Telecom 路径同时 `launchMainActivity/launchCallActivity` 打开承接页面（见 §7 流程）。

### 6. 通话：后台/锁屏来电展示

**根因（已实证，`CallNotificationManager.kt`）：** `fullScreenIntent` 与 `contentIntent` 都复用**接听广播** PendingIntent——锁屏全屏展示或点通知正文即等于点了[接听]。

**修复：**
- `showPendingIntent`：全屏意图与正文意图均指向 `CallActivity`（Activity 意图，FLAG_ACTIVITY_NEW_TASK|SINGLE_TOP）——**仅展示**。
- 展示（showPi）/接听（actionAnswer 广播）/拒绝（actionReject 广播）三动作独立、各挂 callId 语境（CallManager.callId）。
- CallStyle 分支（API31+ 且 PhoneAccount 就绪）：`CallStyle.forIncomingCall(person, rejectPi, answerPi)`（系统自带全屏/横幅呈现）；回退分支：`setFullScreenIntent(showPi, true)` + 显式接听/拒绝按钮——两分支全屏能力都指向展示页。
- **Android 14+ 全屏授权**：`canUseFullScreenIntent()` 检查；未授权时系统自动降级横幅（不伪称必定全屏）；CallActivity 内提供"去授权锁屏全屏来电"设置入口（`ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`）。
- 权限核对：渠道（calls_ring, IMPORTANCE_HIGH + USAGE_NOTIFICATION_RINGTONE）、`MANAGE_OWN_CALLS`、`USE_FULL_SCREEN_INTENT`、`FOREGROUND_SERVICE_PHONE_CALL`、`POST_NOTIFICATIONS` 均已在 Manifest 声明；运行时通知权限由 AppHome `_primeNotificationPermission` 上下文式申请（不假定 Manifest 声明即已生效）。
- 不依赖后台 `startActivity` 作为唯一方案：`launchCallActivity` 尽力尝试（try/catch 记录受限），全屏意图通知兜底；不吞异常隐藏失败原因（catch 内注释指明兜底路径）。
- 原生/Flutter 通知交接：两侧同 ID 41001（calls_ring 渠道）互替不叠加；Flutter 接管（accept → phase 变化）经 `reportCallState` 驱动原生 `cleanupCall/dismissPresentation`；`CallActivity` 监听 `CallManager` UI 事件，远端取消/超时/结束时自动 `finish()`（不再留悬挂页面）。
- Telecom 自管理核对：`CallConnection` 设 `PROPERTY_SELF_MANAGED`；`onCreateIncomingConnectionFailed` 覆写（系统拒绝接入 → 清理呈现）；连接由 `CallManager.attachConnection` 按通话持有，结束时 `setDisconnected + destroy`；onAnswer 只把连接转 ACTIVE（Telecom 层语义），应用层连接成功仍以 Flutter `reportCallState(connected)` 为准。

### 7. 通话：关联、状态同步与结束清理

**修复：**
- **推送时间戳不再等于新电话**：`PushEventDispatcher.dispatch(call)` 先查 `CallManager.hasActiveCall()`——正在呈现（ringing/answering/active）时忽略重复推送；`CallManager.onIncoming` 同样幂等。callId 仅为原生呈现关联标识（"call-<ts>"），真实通话存在与类型由 Matrix 同步确认（`confirmed` 标志 + `reportCallState(video:)` 更新）。
- **动作请求与状态回报单向流动**：用户动作 原生→Flutter（callAccepted/callRejected 事件）或 Flutter 内（页面按钮 → controller）；状态回报只 Flutter→原生（`reportCallState`），`updateFromFlutter` 只更新呈现并通知**仅 UI 监听**（`uiListeners`，绝不回发 Flutter）——无事件循环。
- **状态机**：`idle → ringing（唤醒呈现）→ answering（用户请求接听，绝不假定已连接）→ active（Flutter 回报 connected）→ ended`。`CallForegroundService` 60s 无应答超时现在调 `CallManager.onEnded()`（原来只 stopSelf，留下悬挂 ringing）。
- **按通话维度清理**：`CallManager.cleanupCall()`（幂等）：来电通知取消 + 铃声前台服务停止 + 悬浮球隐藏 + Telecom Connection 断开销毁；**不触碰普通消息同步的保活前台服务**（那由 `ForegroundServiceArbiter` 仲裁，未改）。重复结束事件幂等（只补清理不重发事件）。登出（AppHome dispose）→ 协调器 `dispose()` → `endCall` 通知原生清理 + 仲裁器清空。
- **恢复通话页覆盖三相位**：`CallUiManager` 新增——`connecting/connected` 且 app 前台且页面缺失且非主叫页 → 补开通话页（幂等 `_incomingOpen` 守卫，不重复压入）；`app_home.didChangeAppLifecycleState(resumed)` 对 ringing/connecting/connected 调 `showIncomingCall`（此前 connecting/connected 只显示前台服务通知，页面缺失时回 App 看不到通话页）。
- **CallManager 状态与真实媒体状态核对**：`updateFromFlutter('connected')` 才转 active 并 `connection.setActive()`；answering 期间 CallActivity 显示"正在接通…"（仅挂断，不提供重复接听）。

### 8. 个推在线/离线流程核对（结论 + 待核实项）

**在线透传（进程存活）——代码链路已核对：**
Synapse push gateway → `services/getui-bridge`（载荷白名单：仅 CID/notify_id/type/ttl，transmission 仅 `{"type":"call"|"message"}`）→ 个推 SDK → `ChatFlowGetuiIntentService.onReceiveMessageData` → `GetuiReceiver.onTransmit` → `PushEventDispatcher.dispatch("call")` → 原生来电呈现（CallManager ringing + Telecom reportIncoming + CallStyle 前台服务 + CallActivity 尽力全屏）→ Matrix 同步确认真实通话 → 用户[接听] → Flutter accept → WebRTC。
- 服务端测试 `tests/getui_bridge`（24 项）本地通过（命令见下）；出站白名单/离线通道断言在 `test_bridge.py:128-145`。

**离线（进程被杀）——如实限制，不是"已打通原生全屏来电"：**
- 个推厂商通道（`push_channel.android.ups.notification`）只携带**通用文案**通知 + `click_type=startapp`，**不携带 transmission**——杀进程后不会出现原生全屏来电页，只有系统厂商通知可点击。
- 点击后路径：拉起 App → Flutter 冷启动 → 账号会话恢复 → Matrix 首次同步 → 若 `m.call.invite` 仍在有效窗口内 → CallUiManager 呈现来电页 → 用户应用内接听；若同步恢复时 invite 已过期/已被 hangup → 呈现"已结束"摘要，无来电页。这是系统推送能力边界内的正确行为。
- **待核实项（无控制台/服务器实际配置证据，不写成已部署事实）：**
  1. 个推控制台厂商通道（小米/华为/OPPO/vivo 等）参数是否已配置——未配置则离线通知不可达；
  2. 服务端 `services/getui-bridge` 容器的 AppKey/AppSecret 环境变量与 .env 一致性（本地仅代码审查，未 SSH 核验）；
  3. 真机离线到达率与厂商通知点击是否稳定拉起 App（需真机）。
- **E2EE 边界**：transmission 仅 type 类别，无房间/事件/正文/密钥/媒体；本次修复未扩大推送载荷隐私范围（`reportCallState` 只传 phase/video 布尔，经 MethodChannel 本地进程内通信，不经推送服务）。

---

## 二、来电端到端流程（修复后）

```
[主叫] 业务页 → CallPage(controller.start) → m.call.invite（E2EE 信令）
[被叫·在线] 个推 type=call 透传 → PushEventDispatcher（幂等）
  → CallManager.onIncoming(ringing) → Telecom addNewIncomingCall + CallStyle FGS + CallActivity(尽力)
  → NativeCallBridge emit incomingCall → Dart: 仅登记+呈现（不接听）
  → Matrix 同步 m.call.invite → CallController ringing（类型=实际同步值）
  → 前台：CallUiManager 推来电页；后台：系统全屏/横幅通知持续
[用户接听] 通知[接听]广播 / CallActivity[接听] / Telecom onAnswer / 应用内[接听]
  → CallManager: ringing→answering（绝不假定连接成功）
  → notifyUserAction(callAccepted)【Flutter 未就绪 → PendingCallActions 暂存+拉起 App】
  → Dart _answerFromUser：
      phase==ringing → accept() 恰好一次（权限→Matrix answer→ICE）
      phase==idle   → 仲裁器登记（绑定 callId/15s 期限/多重取消）→ 响铃到达即接听一次
  → Dart reportCallState(connecting/connected) → 原生 answering→active + 悬浮球
[恢复] 回前台（点图标/通知正文/CallActivity"回到通话"）→ connecting/connected 页面缺失则补开（幂等）
[结束] 挂断/拒接/远端取消/60s 无应答/ICE 失败
  → Flutter phase ended/failed → reportCallState(ended)
  → CallManager.onEnded：emit callEnded（对端/页面联动）+ cleanupCall
     （通知/铃声服务/悬浮球/Connection 按通话清理；不动消息保活服务）
```

## 三、冷启动动作：关联、保存、消费、过期

| 阶段 | 机制 |
|---|---|
| 保存 | 引擎未起/未握手时用户点[接听/拒绝] → `PendingCallActions.store(callId, action)`（含时间戳；仅进程内存，无敏感明文）+ 拉起 App |
| 恢复 | AppHome initState → `ready` 握手（原生标记 flutterReady，返回未消费动作 + activeCall）→ `getActiveCall` 权威查询 |
| 匹配 | 账号会话已恢复（AppHome 为登录后根）；answer → 仲裁器待接听（绑定原生 callId）；Matrix 响铃到达且 callId 匹配 → accept 一次 |
| 消费 | 原生 `drain` 取出即标记；Dart 侧按相位幂等（ringing 才 accept） |
| 过期 | 原生 >30s 丢弃；Dart 仲裁器 >15s 作废；新通话（不同 callId）呈现即作废旧请求；登出全清 |

## 四、修改文件清单

**Dart（apps/mobile_flutter/lib/…）**
- `features/matrix/device_gallery_source.dart`：缓存分桶/权限范围/`samplePositionsFor`/`loadVideoFirstFrame` 多点位/`VideoFirstFrameStore`（关键函数：`GalleryAccessCache.recentAlbum`、`permissionScopeChanged`、`samplePositionsFor`、`loadVideoFirstFrame`、`VideoFirstFrameStore.load/_drain/_recordFailure`）
- `features/matrix/image_picker_page.dart`：`_loadEpoch` 批次守卫、`_observeGalleryChanges`、`_reloadIfScopeChanged`、`_VideoFirstFrameCell`（懒加载+重试入口）
- `features/matrix/native_call_coordinator.dart`（**新增**）：`NativeCallArbiter`、`NativeCallChannel`、`NativeCallCoordinator`
- `app_home.dart`：双通道处理器重构（删除自动接听分支与 `_autoAcceptWhenRinging`）、`nativeCalls` 接线、dispose 清理
- `features/matrix/call_ui_manager.dart`：connecting/connected 前台补开通话页（幂等）

**Android（android/app/src/main/kotlin/com/liuhetong/mobile/…）**
- `call/PendingCallActions.kt`（**新增**）
- `call/CallBridge.kt`：chatflow/call 收敛为 dismiss；`NativeCallBridge` 重构（ready 握手/reportCallState/getActiveCall/answerCall/rejectCall/endCall/notifyUserAction 暂存）
- `call/CallManager.kt`：状态机（answering/confirmed）+ UI 监听 + `updateFromFlutter` + `cleanupCall`/`dismissPresentation`
- `call/CallNotificationManager.kt`：全屏/正文意图 → CallActivity；`canUseFullScreenIntent` + 设置入口
- `call/IncomingCallReceiver.kt`：动作经 CallManager（陈旧通知只清理）
- `call/CallActivity.kt`：真实状态监听（结束自动关闭）、answering 渲染、回到通话=拉起主 Activity、Android14 授权入口
- `call/CallConnectionService.kt`：连接注册进 CallManager、`onCreateIncomingConnectionFailed`、`CallConnection` 防递归 finish
- `call/CallForegroundService.kt`：60s 超时 → `CallManager.onEnded()`
- `call/CallOverlayService.kt`：监听器注销防泄漏、常量更新
- `push/GetuiReceiver.kt`：重复推送幂等 + 唤醒语义注释
- `MainActivity.kt`：桥接初始化顺序修复 + `cleanUpFlutterEngine`
- `app/build.gradle.kts`：`testImplementation(kotlin("test"))`

**Android 测试（新增）**：`app/src/test/kotlin/com/liuhetong/mobile/call/PendingCallActionsTest.kt`（3 用例）

---

## 五、验证记录（实际执行的命令与结果）

| # | 命令 | 结果 |
|---|---|---|
| 1 | `flutter analyze --no-pub`（apps/mobile_flutter） | **No issues found** |
| 2 | `flutter test test/features/matrix/native_call_coordinator_test.dart` | **12/12 通过**（验证 1/2/3/4/5/7：来电不接听、单次接听、冷启动恢复、过期/取消不串扰、重复事件、结束清理） |
| 3 | `flutter test test/features/matrix/device_gallery_source_test.dart` | **21/21 通过**（含缓存分桶 common→video→common、采样位置、协调器并发/退避/预算/合并/超时、缓存损坏失效） |
| 4 | `flutter test test/features/matrix/image_picker_page_test.dart` | **10/10 通过**（含验证 11 快速切换旧请求不覆盖、验证 12 失败占位+重试+选择不受阻） |
| 5 | `flutter test test/features/matrix/call_ui_manager_test.dart` | **7/7 通过**（含验证 8 后台接听→回前台补开页面且不重复压入） |
| 6 | `flutter test test/features/matrix/video_first_frame_cache_test.dart` | **3/3 通过**（既有测试更新至新架构：落盘命中/失败不落盘/成功 memoize 行为级验证） |
| 7 | `flutter test`（全量） | 首轮 825 过 / 2 挂（均为 `video_first_frame_cache_test` 旧断言，已更新）；**修复后全量重跑见下** |
| 8 | `gradlew.bat :app:compileStandardDebugKotlin :app:testStandardDebugUnitTest` | 见下（构建节） |
| 9 | `flutter build apk --debug --flavor standard` | 见下（构建节） |
| 10 | `PYTHONPATH=services/getui-bridge .venv/Scripts/python.exe -m pytest tests/getui_bridge -q` | **24 passed**（出站载荷白名单/离线通道断言） |

> 说明 #7：全量首轮的 2 个失败为既有 `video_first_frame_cache_test.dart` 对旧实现（单点抽帧、`_memoizedFirstFrame` 源码断言）的过时断言；按新架构更新后单文件通过。行为意图（首次落盘/二次命中零抽帧/重复调用一次抽帧）全部保留且新增行为级断言。

## 六、构建结果

- **Kotlin 编译 + JVM 单测**：`gradlew.bat :app:compileStandardDebugKotlin :app:testStandardDebugUnitTest --console=plain`
  - `PendingCallActionsTest`：**3/3 通过**（暂存/一次消费/过期丢弃/同通话去重）
  - Kotlin 编译通过（含全部通话层重构文件）
- **APK**：`flutter build apk --debug --flavor standard` ——结果见下方"构建产物"（本地 debug 构建，未发布）。

## 七、尚未解决 / 环境限制 / 需真机验证

**环境限制（如实记录）：**
- 本环境无 Android 设备/模拟器：一切真机行为（Telecom 系统呈现、锁屏全屏、厂商通道）无法端到端执行；
- 个推控制台/服务端容器无访问证据：离线厂商通道配置列为待核实项（§一.8）。

**需用户真机验证的场景清单：**
1. 在线来电（App 后台/锁屏）：CallStyle 全屏或横幅 + 系统铃声；点通知**正文**只展示来电页、不接听；点[接听]才接通。
2. 来电到达但**不操作**：绝不自动接听（60s 无应答自动结束并清理）。
3. 杀进程后来电：仅厂商通道通用通知可点 → 拉起 App → 同步恢复来电页（若无来电则为已结束摘要，无假来电）。
4. 杀进程后点通知[接听]（若有 CallStyle 通知残留）：动作暂存 → 冷启动 ready 恢复 → 响铃同步到达即接听一次；超过 30s 的动作被丢弃。
5. 重复推送（同一来电多次唤醒）：只呈现一通电话、一个通知、一页。
6. 后台接听后回 App：通话页自动补开（connecting"正在建立加密连接…"→ connected 计时）。
7. Android 14+ 未授权全屏通知：来电降级横幅 + CallActivity 内"去授权"入口；授权后下次锁屏全屏。
8. 通话结束：通知/铃声/悬浮球/CallActivity 全部收尾；消息保活通知不受影响。
9. 相册：最近图片 ↔ 本地视频 快速来回切换（视频列表只含视频）；弱网下切换旧列表不回闪；部分照片授权下仅显示已选照片、去设置改"全部照片"后返回自动刷新；拍摄新视频后选图页自动刷新；无法解码的视频显示占位+可重试、仍可勾选发送。
10. 语音/视频类型：视频来电的通知文案与通话页类型与实际一致（以同步结果为准）。

**已知未做（超出本次范围或需服务器操作）：**
- 服务端 `services/getui-bridge` 无需代码改动（载荷合规已由测试保证）；控制台厂商通道配置需用户在个推后台完成。
- iOS 侧原生来电（CallKit）不在本次范围（原生通话层为 Android Telecom）。

## 八、最终交付分类

**已修复并验证（自动化测试/静态检查/编译通过）：**
- 相册缓存混用（RequestType 分桶）、权限范围失效、媒体库变化失效
- 快速切换相册旧请求不覆盖新结果（请求批次）
- 视频封面：多点位采样、失败有限重试+退避、有界并发、并发合并、成功缓存、损坏缓存失效、失败占位+重试入口
- 来电自动接听（事件严格区分 + 绑定式待接听仲裁）
- 桥接初始化顺序、ready 握手、冷启动动作暂存/恢复/消费/过期（Dart + Kotlin 双侧测试）
- 全屏/正文意图指向展示页（源码级 + 编译级验证；真机渲染需用户验证）
- Telecom 失败路径、CallActivity 真实状态监听、60s 超时联动清理
- 状态回报单向流动（无事件循环）、按通话维度清理（不动消息保活）
- connecting/connected 页面缺失补开（幂等）
- 重复推送幂等（不造第二通电话）
- getActiveCall/ready/reportCallState/endCall 接口有真实调用方

**已实现但尚未运行自动化验证（需真机）：**
- Telecom 自管理连接在真机系统上的实际呈现与 onAnswer 路径
- CallStyle 通知/全屏意图/锁屏行为、Android 14+ 授权降级
- 个推离线厂商通知点击冷启动恢复
- 相册在真实媒体库上的部分授权/变更监听行为

**仍有阻塞（无自动化验证手段）：**
- 个推控制台厂商通道配置（无访问权限，列为待核实项）
- 服务端 bridge 容器 env 核验（本次未做 SSH 检查；服务端代码无需改动）
