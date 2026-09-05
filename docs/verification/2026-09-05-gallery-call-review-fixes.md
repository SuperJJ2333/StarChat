# 图库视频与通话审计修复（gallery-call-review 5 项）

**日期：** 2026-09-05　**输入：** `docs/verification/2026-09-05-gallery-call-review.md`
**基线：** b80049b 工作区（含 27 项审计修复）
**验证环境：** flutter analyze 无问题；flutter test 全量 **856/856 通过**（含新增 9 个用例）；`gradlew :app:compileStandardDebugKotlin` **BUILD SUCCESSFUL**；arm64 debug APK 已重建并安装 Mi 6（versionCode=39，lastUpdateTime 13:51）。

## P1-1 CallStyle 分支漏设 fullScreenIntent —— 已修复并编译验证
- **根因：** `setFullScreenIntent` 只在 else（非 CallStyle）分支设置；CallStyle 是样式/动作模板，不自动生成打开 CallActivity 的全屏意图。
- **修复：** `CallNotificationManager.buildIncoming`——全屏意图移到**共同路径**（`canUseFullScreenIntent` 门控，Android 14+ 未授权时系统自动降级横幅）；CallStyle 分支保留样式，回退分支保留显式按钮。意图仍指向展示 Activity，绝不接听。
- **验证：** Kotlin 编译通过；UI 行为需 API31+ 真机（Mi 6 为 API28，走回退分支——由既有逻辑覆盖）。
- **限制：** API31+ CallStyle + 全屏叠加的系统行为留 K80 真机验收。

## P1-2 回前台只取消通知不恢复来电页 —— 已修复并测试实证
- **根因：** `handleAppResumed` 仅 `hideIncoming`；后台响铃未推 route，回前台 phase 无变化不再触发 `_handleCallState` → 通知没了、页面也缺失。
- **修复：** `CallUiManager.handleAppResumed`——ringing/connecting/connected 一律重跑 `_handleCallState()`（推页幂等、尊重主叫页守卫、通知在页面就绪路径收起）。
- **验证（先失败后修复）：** 按审计复现场景写测试——后台视频响铃 → `resumed=true` → 仅调 `handleAppResumed()`：修复前 `isIncomingPageOpen=false`（复现审计结论），修复后 **true** 且"邀请你进行视频通话"可见（`call_ui_manager_test.dart` 新增 1 例，全套 8/8 通过）。

## P1-3 视频流变化无独立绑定触发 —— 已修复并测试
- **根因：** `srcObject` 只在 renderer 初始化完成与 controller 通知时赋值；SDK `onStreamAdd/onStreamRemoved/onStreamChanged` 未转发——流在状态事件后到达/重建时画面停留 null/旧流；另有 init/dispose 竞争（初始化未完成写入抛异常、销毁后写入泄漏）。
- **修复：**
  - `matrix_call_adapter.dart`：新增 `mediaStreamChanges` 广播流——订阅 `call.onStreamAdd/onStreamRemoved` 并对每个 WrappedMediaStream 挂接 `onStreamChanged`；`_ended/dispose` 统一清理订阅。
  - 新增 `media_renderer_binding.dart`：`MediaRendererBinding<T>`（泛型纯逻辑：读流→写 renderer，幂等仅实例变化时写，dispose 后空操作）。
  - `call_page.dart`：`_renderersReady/_disposed` 守卫（初始化期间销毁则不再写 renderer）；订阅 `mediaStreamChanges` 驱动重绑；绑定经两个 Binding 实例（每秒计时 setState 不再反复赋值 srcObject）。
- **验证：** `media_renderer_binding_test.dart` 4 例——流后到绑定、重建换绑/移除解绑、幂等不重复写、dispose 后空操作（注入替身，无平台通道）。
- **限制：** adapter 侧 SDK 事件转发为代码级接线（CallSession 具体类不可在单测构造）；真实"流后到时序"需真机通话日志确认。

## P2-1 视频等待页 UI —— 已修复
- **根因：** 来电/等待态直接渲染 `_remoteRenderer`（远端未接通无画面 → 黑块）；本地画中画 `Align` 嵌在 Column 内无法到达屏幕右上角。
- **修复（`call_page.dart`）：**
  - 来电响铃/建立中（语音体路径）：统一**头像呈现**（与语音来电一致），不再渲染未就绪的远端画面；
  - 主叫视频等待（视频体路径）：本地画面铺满（微信语义：等待时看自己），接通后切远端；
  - 画中画改为 Stack 内 `Positioned(top: safeTop+64, right)` —— 真正屏幕右上角，仅接通后显示。
- **验证：** 全量测试通过（call_page 既有场景断言含"正在建立加密连接…"等文案）；像素级观感留真机。
- **说明：** 按审计建议方向实现（统一头像/分态呈现/右上角 PiP），非 Figma 复刻；Figma 视觉复核未做（无可用工具）。

## P2-2 封面字节损坏后禁用重试 —— 已修复并测试
- **根因：** `Image.memory` `errorBuilder` 固定 `showRetry=false`——磁盘缓存字节非空但不可解码时永远占位无重试；且即使有重试，普通重载仍会命中同一损坏缓存。
- **修复：**
  - `VideoFirstFrameStore.invalidateById`：清预算/退避 + 标记强制重抽；`load` 命中标记走 `forceLoader`（`loadVideoFirstFrame(ignoreCache: true)` 跳过磁盘读，重抽成功覆盖缓存文件并恢复正常缓存）；
  - UI：解码失败 errorBuilder 也显示重试按钮；重试点击改用 `invalidateById`（绕过缓存强制重抽）。
- **验证：** `media_audit_test.dart` 新增 2 例——成功缓存被强制重抽绕过且拿到新字节、恢复后不再强制；预算耗尽后 invalidate 仍可恢复。横幅外另有 **limited 授权入口**（审计"已确认/未确认"节要求）：授权范围为 limited 时选图页顶部显示"仅可访问你选中的部分照片/视频 + 管理"横幅（`PhotoManager.presentLimited()`，不支持时退系统设置）——`image_picker_page_test.dart` 新增 1 例（limited 显示/full 不显示）。

## 审计"已确认/未确认"节的对应
- 无视频条目/条目黑/预览失败三分法：已分别由（权限+limited 横幅+变更监听）/（封面多点位+损坏重试）/（预览页重试降级，既有）覆盖；K80 真实 MediaStore 数量与权限状态仍需现场核查。
- 前置摄像头：SDK 默认 `facingMode=user`（审计已确认非缺陷），未改动；真实 getUserMedia 错误待 K80 日志。
- MI 6（API28）不能验收 API31+ CallStyle/API34+ 全屏与部分授权——与审计一致，留 K80。

## 真机验收要点（新增/更新）
1. （K80/API31+）锁屏来电：CallStyle 分支现在应能全屏唤起来电页；Android 14+ 未授权时降级横幅。
2. 任意设备：后台来电 → 回前台（点图标而非通知）→ 来电页必须出现（本轮修复的核心场景）。
3. 视频通话：来电响铃显示对方头像（非黑块）；主叫等待看到自己；接通后远端主画面 + 右上角本端小窗。
4. 视频流晚到/重建（如对方先关摄像头再开）：画面应自动恢复（不再停留黑屏）。
5. 图库：部分授权下顶部出现"管理"入口；封面损坏（可见占位+重试）点重试后应恢复真实帧。
