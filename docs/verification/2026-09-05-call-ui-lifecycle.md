# 通话 UI 生命周期/后台唤醒/通知链路修复（2026-09-05）

按规格六节实现；未触碰 Matrix/WebRTC 协议与加密（matrix_call_adapter
仅加日志与 kConnected 丢失兜底，不改信令）。

## 实现映射

| 规格 | 实现 |
| --- | --- |
| §一 CallUiManager | 新增 `lib/features/matrix/call_ui_manager.dart`：唯一通话 UI 呈现者。ringing+前台→根 Navigator 推 CallPage（修复旧 overlay 在推入路由**之下**被盖住的缺陷）；ringing+后台→calls_ring 全屏通知；connected→保持页面+通话中前台服务；ended/failed/permissionDenied→延迟 2s 关闭（窗口内抖动恢复即取消）。普通页面不再自听 CallController |
| §二 navigatorKey | `callNavigatorKey` 定义于 call_ui_manager.dart，挂载 `CupertinoApp.navigatorKey`（main.dart）；统计助手复用同一根 Navigator |
| §三 AppHome | `initState` attach 管理器（含 mediaBackend/outgoingCallPageVisible），`_handleCallState` 只保留业务钩子（提醒抑制/通话摘要），来电委托 `callUi.showIncomingCall(calls)`；移除 Stack 内来电覆盖层 |
| §四 CallPage | `hasConnectedOnce`：接通过一次后终态有 3s 缓冲（Timer 直接 pop；抖动恢复取消）；从未接通立即退出。connecting 等中间态从不退出（原语义保持） |
| §五 adapter | 全状态日志 `[matrix-call] state=...`（inviteReceived/answerSent/connected/ended 明确打印）；`ConnectedFallbackWatcher`：accept 后 10s 内 `pc.connectionState==connected` 而 kConnected 未到→补发 connected（恰一次；SDK 事件迟到去重） |
| §六 通知渠道 | calls_ring 已达标（Importance.max/Priority.max/chatflow_ringtone/fullScreenIntent/category=call/点击回前台），无需改动——本轮经 CallUiManager 统一驱动 |

## 测试（全部先红后绿）

- `call_ui_manager_test.dart`（6）：**规格验证场景 1/2**（任意页面之上立即弹
  来电页）、**场景 3**（后台→系统全屏通知不推页）、**场景 4**（接听后
  00:01/00:02/00:03 逐秒页面持续）、**场景 5**（挂断延迟关闭回原页）、
  connected→ended 抖动不关页且恢复取消、未挂载安全。
- `call_page_test.dart`（+3）：hasConnectedOnce 缓冲/缓冲后退出/未接通
  立即退出。
- `call_connected_fallback_test.dart`（4）：事件先到停轮询不补发、事件
  丢失补发恰一次、10s 超时放弃、stop 立停。
- 门禁：flutter analyze **0**；全量 flutter test **774 passed**。

## 部署

- 开发版（debug，x86_64 拆分 128.6MB）已安装雷电模拟器
  （127.0.0.1:5555，Android 9）：versionName **0.3.35** / versionCode
  **4038**，应用已启动到登录页（签名由 release 换 debug，需重新登录）。

## 真机/模拟器验证对照（场景 1-5）

1/2. A 呼 B，B 停聊天页或联系人页（或任何推入的子页面）→ 全屏来电页
   立即覆盖（根 Navigator 推送，任何路由盖不住）。
3. B 退后台/锁屏 → 系统全屏来电通知（响铃渠道，系统铃声）。
4. B 接听 → 连接中→00:01/00:02/00:03 持续计秒，页面不消失。
5. 挂断 → 约 2 秒缓冲后页面关闭回原页面。

诊断日志：`adb logcat -s flutter | grep -aE "matrix-call|call-fallback"`。
