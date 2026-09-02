# 畅聊APP「消息会话 + 通话」UI BUG 修复任务清单（2026-08-31）

> 精准化自用户需求，全部条目已对照当前代码定位根因与落点。
> 涉及分支基线：0.3.20+23（已发布）。建议按 T1→T2→T3→T4 顺序开发
> （T1/T2 同链路），T5 独立并行。合计预估 3.5~5 人日 + 真机联测。

---

## T1 通话结束后移除多余"通话已结束"页面 【优先级 P0 · 0.5 人日】

**现状与根因**
- 呼出通话页由 `app_home.dart::_openCall` 以路由 push（`CallPage`）；
  来电则为 `app_home.dart` Stack 内 `incomingCallActive` 覆盖层。
- `CallPage.build`（`lib/features/matrix/call_page.dart`）在
  `phase == ended / failed / permissionDenied` 时渲染"状态文案 + 关闭按钮"
  的静态页，需手动点"关闭"才返回 —— 即用户看到的"通话已结束"多余页面。
- 来电覆盖层已自动隐藏（`_callChanged` 中 ended 时
  `incomingCallActive = false`），无此问题。

**修复方案**
1. `CallPage`：`didUpdateWidget`/监听器内检测 `phase` 进入
   `ended/failed/permissionDenied` 时，延时 ≤1 秒自动
   `Navigator.maybePop(context)`（弹出前保持原通话画面淡出，不渲染
   "通话已结束"独立状态；删除 ended 态的"关闭"按钮分支）。
2. `app_home.dart::_callChanged`：ended 时同步复位 `callPageVisible`。
3. `status` getter 中 ended/failed 文案保留用于**通话页内瞬时提示**
   （可选：挂断按钮点击后 1 秒内显示"通话已结束"再 pop；禁止停留）。

**验收标准（可测）**
- [ ] AC1 呼出语音/视频通话 → 任一方挂断后 ≤1 秒，通话页自动关闭，
      停留在消息会话页，会话页滚动位置与输入内容不丢失。
- [ ] AC2 来电拒接/对方取消后，来电覆盖层立即消失（现状已满足，回归确认）。
- [ ] AC3 "通话已结束"独立页面不再出现（全流程遍历：接通后挂断、
      对方拒接、超时取消、网络中断四种结束路径）。
- [ ] AC4 快速连挂两次不产生路由异常/黑屏（pop 幂等，`maybePop` 防护）。

**测试**：`test/features/matrix/call_page_test.dart` 新增
"ended phase auto-pops the route" Widget 用例（mock 路由观察 pop 调用）；
`app_home` 回归用例确认覆盖层复位。

---

## T2 通话结束后在会话页展示通话状态与时长 【优先级 P0 · 1.5 人日】

**现状与根因**
- 通话结束**不产生任何会话消息**：`MatrixCallBackend._ended`
  （`lib/features/matrix/matrix_call_adapter.dart`）仅广播内部事件，
  无落库/落时间线动作；`RoomMessageKind`（`room_timeline_controller.dart:5`）
  亦无 call 类型。
- 参照模式：红包/转账的自定义消息链路
  （`changliaoRedPacketMessageType` → `RoomMessageKind.redPacket` →
  `WeChatRedPacketCard`），完全可复用。

**修复方案**
1. **新自定义消息** `changliaoCallEventType`（仿
   `changliaoRedPacketMessageType` 定义于
   `matrix_room_timeline_adapter.dart`）：呼叫方在通话结束时 sendEvent，
   content 携带 `call_type`（voice/video）、`call_status`（ended/cancelled）、
   `duration_ms`（接通时刻→结束时刻；未接通为 0）。
2. **状态机对接**：`CallController` 已有 `connectedAt`
   （本轮已实现）与超时/拒接/挂断路径；在 `app_home._callChanged` 的
   ended 分支，由**呼叫方**（`_openCall` 发起方）组装并发送（仅发起方发送，
   双端各显示一条、不重复）；被叫端收到该消息即自然渲染。
3. **渲染**：`RoomMessageKind` 新增 `call`；adapter 映射该事件 →
   新 ViewModel 字段（callType/callStatus/callDuration）；新 Widget
   `WeChatCallBubble`（电话 icon + 文案），样式对齐现有气泡（圆角/字号/
   对齐/时间戳沿用 `WeChatMessageBubble` 体系）。
4. **文案**：接通 → "通话时长 mm:ss"（分钟两位补零，如 `03:25`，与
   `formatCallDuration` 统一，需求文案"个位数"以示例 `03:25` 为准）；
   未接通（对方未接/主动取消/超时/拒接）→ "已取消"。
5. **防泄漏**：确认 `m.call.*` 信令事件不落入消息时间线（adapter 目前仅
   映射 MessageTypes.*，需回归验证；若泄漏则在 timeline filter 排除）。

**验收标准（可测）**
- [ ] AC1 双账号联测：语音通话接通 3 分 25 秒后挂断，双方会话页出现
      一条"📞 通话时长 03:25"消息，样式与普通消息一致（含时间/对齐）。
- [ ] AC2 视频通话同样展示，icon/文案与语音可区分（或按需求仅电话 icon）。
- [ ] AC3 未接通三种路径（主叫取消、超时无应答、被叫拒接）→ 显示
      "📞 已取消"，**不显示时长**。
- [ ] AC4 消息随时间线持久化：杀进程重进会话后仍在。
- [ ] AC5 短于 1 秒的通话按"已取消"处理（与现有 <1s 无效通话规则一致）。
- [ ] AC6 加密房间内该消息走 E2EE（复用 sendTextEvent 加密通道，无明文）。

**测试**：adapter 映射单测（自定义事件 → call ViewModel）；
`WeChatCallBubble` Widget 用例（两种文案/两种 callType）；
`CallController` 上报 duration 的单测；真机双账号联测 AC1–AC3。

---

## T3 语音消息播放动效（真实进度 + 暂停/继续） 【优先级 P1 · 1 人日】

**现状与根因**
- 本轮已实现 QQ 式扫过动效（`lib/ui/chat/wechat_voice_bubble.dart`
  `_VoiceWavePainter`），但：
  1. 进度由**点击时刻起算的定时器**估算，与音频真实播放进度存在漂移，
     不满足"与音频实际播放进度保持一致"；
  2. 播放中再次点击为**停止**（`VoicePlaybackController.toggle` →
     `engine.stop()` + 清 playingIds，高亮复位），不支持暂停/继续。

**修复方案**
1. `VoiceAudioEngine`（`voice_playback_controller.dart`）扩展：
   `pause()` / `resume()` / `Stream<Duration> get position` /
   `Stream<void> get completed`（已有）/ `Duration? get duration`。
   `AudioplayersVoiceEngine` 用 audioplayers 的
   `onPositionChanged` / `pause` / `resume` 实现。
2. `VoicePlaybackController` 状态机：idle → playing → paused → playing…；
   暂停保留 `playingIds`（新增 pausedIds 或 state 字段），气泡按
   `position / voiceDuration` 驱动扫过进度；`stopAll` 语义保留。
3. `WeChatVoiceBubble`：进度改由控制器注入的真实 position 计算
   （替换估算定时器）；paused 态高亮**定格**；自然结束经 `completed`
   复位（已有）。再次点击行为：playing→暂停、paused→继续。
4. 兼容：`AnimatedBuilder`+`CustomPaint` 重绘仅波纹区域，无整页刷新，
   中低端机无卡顿（现有实现已满足，补 60fps 冒烟）。

**验收标准（可测）**
- [ ] AC1 点击语音气泡：开始播放 + 扫过高亮启动；播放到 50% 时高亮
      约扫过音纹 50%（误差 ≤1 根条，与系统播放进度一致）。
- [ ] AC2 播放中再次点击：音频暂停，**高亮定格当前位置**不闪烁不跳动。
- [ ] AC3 暂停后再次点击：从暂停位置继续播放与扫过（不重头）。
- [ ] AC4 播放自然结束：高亮自动复位为默认色，气泡回 idle 态。
- [ ] AC5 切换到另一条语音：上一条复位、新条从头播放（单语音互斥保留）。
- [ ] AC6 拖动/锁屏/切后台回来后，进度显示与真实播放一致（恢复后校准）。
- [ ] AC7 iOS/Android 主流版本流畅无闪烁（真机冒烟）。

**测试**：controller 状态机单测（play→pause→resume→complete、互斥、
position 流）；bubble Widget 用例（真实 position 驱动高亮比例、暂停定格）；
真机双端冒烟。

---

## T4 会话退出后未读角标残留 【优先级 P0 · 0.5 人日】

**现状与根因**
- 列表未读数：`matrix_home_page.dart::_conversationUnread` →
  `ConversationReadState.unreadCount`（`conversation_read_state.dart`）：
  仅当 `markOpened(roomId, lastEventId)` 记录的 eventId **仍等于**
  `room.lastEvent?.eventId` 时才返回 0，否则回落
  `room.notificationCount`（服务器未读数）。
- 进入会话时 `markOpened` 记录的是**进入时刻**的 lastEventId
  （`_openRoom`，matrix_home_page.dart:371）；`RoomPage._load` 调用一次
  `timeline.setReadMarker()`（room_page.dart:332）后**不再续标**。
- **残留场景**：会话内到达新消息（lastEvent 前移）或已读回执尚未被
  下一次 sync 确认时退出 → `opened != lastEventId` → 回落
  `notificationCount`（本地 Room 内存值滞后，仍 >0）→ 红色角标残留。

**修复方案**
1. **退出续标**：`RoomPage` 离开时（`dispose`/PopScope）再次
   `markRead()`，并回调列表侧 `markOpened(roomId, 当前 lastEventId)`
   （通过注入的回调或共享 `ConversationReadState` 单例更新）。
2. **已读即时清零**：`_conversationUnread` 增加"刚退出的会话"短路——
   退出时刻起、直到该房间出现**新的他人消息**前一律返回 0
   （`markOpened` 记录退出时刻的 lastEventId 即已实现该语义，重点是
   在退出时也执行 + 列表退出后 `setState` 重建）。
3. 回归确认 `manualUnread`（手动标为未读）路径不受影响。

**验收标准（可测）**
- [ ] AC1 A 给我发 3 条消息（角标 3）→ 进入会话阅读 → 返回列表：
      角标立即消失（不等待下一次 sync）。
- [ ] AC2 停留在会话页期间 A 再发 2 条 → 返回列表：角标仍为 0
      （在会话内已读）。
- [ ] AC3 返回列表后 A 再发 1 条 → 角标恢复并 +1（未读逻辑不被误清）。
- [ ] AC4 手动"标为未读"的会话行为不回退。
- [ ] AC5 会话内未滚动到底直接返回（快速进出 10 次）→ 无残留、无闪烁。

**测试**：`ConversationReadState` 单测补充"退出续标"场景；
matrix_home_page Widget 回归（角标清零与新消息恢复）；双账号真机联测
AC1–AC3。

---

## T5 安装被安全软件报毒 【优先级 P1 · 1 人日 + 外部扫描周期】

**现状与根因**
- 0.3.17 曾做安全加固（R8 混淆 + 资源收缩 + `--obfuscate` Dart 符号
  混淆 + 符号分离），但 **0.3.18~0.3.20 的发布构建未再携带
  `--obfuscate --split-debug-info`**（发布命令退化，属回归）——
  `libapp.so` 内 Dart 符号/字符串重新裸露，是安全软件灰度启发式
  误报的已知诱因。
- 权限清单已收敛（无 SMS/联系人/定位等敏感权限；`INTERNET/CAMERA/
  RECORD_AUDIO/通知/媒体` 等均为通话与核心功能必需），`usesCleartextTraffic=false`。
- 签名：固定 release keystore（`android/key.properties`），无 `latest`
  依赖，版本与产物可追溯。

**修复方案**
1. **恢复加固构建**：修复合
   `scripts/build_mobile_public_domain.ps1` 中
   `--split-debug-info=$mobileRootuild\symbols` 的路径拼接 bug
   （缺反斜杠，实义为 `<mobileRoot>\build\symbols`），并统一以脚本发布，
   确保 `--obfuscate --split-debug-info` 回到发布链路；产物符号表归档。
2. **权限最小化复核**：逐项注释用途（已在本轮 Manifest 变更处标注），
   移除非必要项；确认 release manifest 关闭 debug/明文流量。
3. **第三方 SDK 审计**：枚举传递依赖（matrix/webrtc/audioplayers/
   photo_manager 等），核对无动态下发可执行代码、无反射加载 dex。
4. **验证协议**：
   a. 腾讯手机管家、360 手机卫士、MIUI/华为/OPPO/Vivo 自带安全扫描
      安装实测（多机型 ≥5 台）；
   b. VirusTotal 全引擎扫描留档比对（关注 Turgen/Heuristic 类报毒），
      与 0.3.17 加固版基线对比误报数；
   c. 应用商店（如上架）预审反馈留档。
5. 输出《安全扫描报告》至 `docs/verification/`，作为发布门禁。

**验收标准（可测）**
- [ ] AC1 发布命令包含 `--obfuscate --split-debug-info` 且路径正确，
      产物中 `libapp.so` 不含明文 Dart 符号（`strings` 抽查）。
- [ ] AC2 ≥5 台主流机型 + 腾讯管家/360/厂商安全中心安装扫描：
      无"病毒/风险"类提示（留存截图与版本号）。
- [ ] AC3 VirusTotal 报毒引擎数 ≤ 加固前基线，且无非组件厂商的
      确定性报毒（Trojan 类）。
- [ ] AC4 功能回归：加固包在模拟器与真机完成核心链路冒烟
      （登录/会话/通话/红包）。

**测试**：`scripts/verify.ps1` 全过 + 发布门禁扫描报告。

---

## 依赖与顺序

- T1 与 T2 同链路（通话页 + 通话消息），建议同一开发负责、T1 先行；
- T3、T4 相互独立可并行；
- T5 与功能开发并行，但**发布门禁**在 T1–T4 合入后统一执行一次加固发布
  与全量扫描。

## 统一回归清单（发布前必测）

- [ ] 双账号真机：语音/视频全流程（发起-接听-挂断-会话消息-时长角标）
- [ ] 语音消息：播放/暂停/继续/互斥/自然结束复位
- [ ] 未读角标：进出会话/会话内收信/新消息恢复
- [ ] `flutter analyze` 0 issue；全量 `flutter test` 通过；
      `scripts/verify.ps1` 通过
- [ ] 加固发布包经 T5 验证协议后发布，`latest_build` 按
      arm64 清单值（`2000+build`）推送更新弹窗
