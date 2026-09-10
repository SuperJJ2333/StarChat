# 2084：语音本机播放专项

日期：2026-09-10。执行计划：`docs/superpowers/plans/2026-09-10-chat-reliability-2084.md`。

## 现象

用户报告 iPhone 15、iOS 26.6（沿用用户原描述，未连接设备核验）：发送语音成功，对方可听，但该手机自己发送与对方发来的语音均不能播放。本次没有该设备、macOS、Xcode 或 Swift 编译器，不能将下列本地测试称为已确认该手机根因或实机修复成功。

## 复现与根因证据

本地读取锁定依赖 `audioplayers 6.8.1`、`audioplayers_darwin 6.5.0`、`audioplayers_android 5.3.0`、`record_ios 2.1.1` 源码，不新增依赖。

- Darwin `AudioContext.apply()` 仅 `setCategory`；`WrappedMediaPlayer.resume()` 仅更新播放参数并调用 `playImmediately`。显式激活 `AVAudioSession.setActive` 经 `controlAudioSession()` 调用，而锁定版本该函数唯一调用点在 `onSoundComplete()`；播放器开始/恢复路径没有显式激活保证。录音、WebRTC 与播放共用音频会话，因此新增开始及恢复前的原生会话准备。这是源码可确认的缺口，尚不能证明它就是用户设备的唯一原因。
- `BytesSource` 并非在 iOS 完全不可用：Dart 会转本地临时文件，Darwin 支持 MIME override。原实现使用 20 位 hash 无后缀路径，重复写同路径且没有应用级释放清理；改为唯一私有临时目录和 `.m4a`/`.wav`/`.aac` 后缀，仍按容器字节识别 MIME，不信任旧消息的 `audio/aac` 标签。
- Android 泛用 `AudioContextConfig` 听筒设置只有 usage 改变，`audioMode` 仍为 `normal`；本次明确听筒为 `inCommunication + voiceCommunication`，扬声器为 `normal + media + isSpeakerphoneOn`，两者内容类型均为 speech。
- 可确定复现的共享控制器问题：下载中第二次点击暂停空播放器，下载结束却开始播放；原生 A 的迟到 play 返回后调用 stop 可能停掉 B；resume 错误向未等待的 UI Future 抛出且仍标记 playing；选择下载较慢的 B 时 A 继续响而 UI 已清除 A。

## 修改

- `voice_playback_controller.dart`：下载态与播放态分离；下载中再次点按取消；原生播放、暂停、恢复、停止串行，代数校验过滤迟到任务，旧任务清理在新任务播放前完成；错误回到可重试状态，不输出音频源/明文日志。切换消息立即停止旧声。
- 新增 `canPlay` 回调及 `isLoading/hasFailed/setEarpiece` 接口供页面接入；播放前及下载后重查通话占用。切路由保留原生源及进度，恢复重新准备会话。
- iOS `AppDelegate.swift`：`chatflow/voice_audio_session` 原生桥，在主线程先检查 `IOSCallsBridge.hasActiveCall` 与 `CXCallObserver`，通话存在时拒绝；之后原子配置 `playAndRecord`、default mode、听筒/扬声器路由、`setActive(true)`。Dart 不先调用会抢占全局 category 的插件方法。
- `IOSCallsBridge.swift`：只增加只读 `hasActiveCall`，不修改呼叫状态机。
- Darwin 语音临时文件仅设备端持有，停止、换源、失败或释放播放器后清理。自然完成后最多保留该播放器的一份临时源，直到下一次停止/换源/页面释放；不在完成事件里抢先删除仍可能被原生 seek/release 使用的文件。进程崩溃后的临时目录由系统缓存策略管理，本次不做跨播放器目录扫描删除。
- 在线附件下载与持久缓存仍通过页面既有 `loadMediaWithCache`；本次未改变 Matrix 加密、解密、业务数据、签名或服务端协议。iOS Info.plist/project 本地化用户改动未编辑。

## 验收

`docs/verification/artifacts/2026-09-10/chat-reliability-2084/voice/` 保存：

- `red.log`：3 个控制器失败（下载取消、原生并发、resume 错误）。
- `source-red.log`：iOS session 准备缺失、Android speaker 路由缺失。
- `file-red.log`：Darwin 仍返回 BytesSource，缺少可控带后缀文件生命周期。
- `android-route-red.log`：听筒实际 audioMode 是 normal。
- `switch-red.log`：新附件下载时没有停止旧声。
- `green.log`：语音源、控制器、气泡共 **31 tests passed**。
- `analyze.log`：3 个变更 Dart 文件 **No issues found**。

测试覆盖 iOS 方法通道先准备后播放/每次恢复、通话占用拒绝先于播放器变更、Android 路由参数、M4A/WAV/ADTS 与未知容器、唯一临时文件换源及失败清理、首次下载缓存、暂停/恢复、自然完成复位、迟到下载、原生 play 串行、dispose、错误可重试。测试内媒体全为合成字节；未上传语音明文或密钥。测试中的方法通道与 AudioPlayer 为替身，不执行 AVPlayer/AudioManager 实机音频输出。

双端影响：Android/iOS 共用控制与缓存入口；iOS 增加原生会话显式激活并使用本地带后缀源；Android 明确听筒通信模式与扬声器媒体模式。Root 负责将路由入口及通话 canPlay 仲裁接入 room_page，并执行跨模块门禁。

尚待实机：iPhone 15 实际系统/构建版本确认；录音后自播与接收语音；静音开关/音量/蓝牙；听筒↔扬声器；连续自然完成后重播与快速换消息；首次在线加载后断网重播；通话/录音抢占；前后台恢复。Windows 无法执行 iOS 编译与这组设备验收，不能宣称已通过。本轮未构建 APK、部署或提交。

## 审查

规格符合性自检：客户端本地播放、单语音所有权、双端共享逻辑、缓存边界保持，未把媒体明文交给服务器。质量/安全自检：无新依赖、无秘密日志，原生通话仲裁先于会话修改，临时源在播放器释放后清理；Root 仍需跨模块审查页面入口与通话监听接线。

首次测试命令在移动端 cwd 下误建了一个空目录树 `apps/mobile_flutter/docs/verification/artifacts/2026-09-10/chat-reliability-2084/voice`，没有生成任何文件。清理空目录的命令被自动审批拒绝（仅返回 `blocked by policy`），未尝试绕过；所有实际证据均位于上方根目录规定位置。

## 追加：页面接线与 HTML demo（同日）

Root 后续授权本 agent 完成页面接线。`room_page.dart` 已连接真实 `canPlay/isLoading/hasFailed/setEarpiece`；下载中显示可再次点按取消的转圈状态，失败气泡显示“重试”，不依赖整页刷新更新气泡。长按语音沿用原气泡菜单，只呈现当前路由的另一个选项“听筒播放”或“扬声器播放”，不向每条消息增加常驻大按钮。

`call_ui_manager.dart` 提供只读 `callAudioActivity`，由现有通话 phase 更新，涵盖请求权限、响铃、连接、通话。RoomPage 仅用于音频仲裁，不另行呈现来电页。活跃通话会停止语音播放并取消录音；录音启动先等待播放器停止，若等待启动过程中发生来电则取消迟到录音。录音/通话期间拒绝语音播放与切路由。原有 videoagent 的 `prepared_chat_video` 逻辑保留。

新增 UI 文件范围：RoomPage、WeChatVoiceBubble、MessageAction/MessageBubbleMenu/MessageActionSheet、CallUiManager 和相应测试。HTML 更新 `frontend/src/components/chat.js`、`anchored-menu.js`、`screens/messaging.js`、`catalog/contracts.js`；voice 样式沿用已有 outgoing 色与 card radius token。Registry `packages/ui-contracts/changliao-component-registry.json` 注册 WeChatVoiceBubble 的 idle/loading/playing/paused/failed 状态及现有 token，无新增设计 token。

Figma 已退役：本次变更仅更新 HTML demo（`frontend/index.html?screen=chat-voice-preview&capture=1`）。浏览器预览截图为 `artifacts/2026-09-10/chat-reliability-2084/voice/voice-demo.png`，已检查加载、失败重试及紧凑路由菜单可见；浏览器点重试与点路由切换实际更新 demo 状态。

- `ui-red.log`：失败气泡没有“重试”的真实测试失败。
- `call-ui-red.log`：来电后音频占用信号仍为 false 的真实测试失败。
- `ui-green.log`：**56 tests passed**，包含语音源、控制器、气泡、菜单、菜单策略和通话 UI 管理器。
- `ui-analyze.log`：9 个相关 Dart 文件 **No issues found**。
- `ui-contract.log`：**PASS，21 components / 331 screens**。
- `html-tests.log`：**135 passed**。
- `demo-browser.log`：截图、重试、切路由浏览器验证 **PASS**。

完整 `scripts/verify.ps1` 由 Root 在跨模块合并后统一执行。上述 Flutter 测试覆盖独立组件及真实控制器契约，未通过设备执行完整 RoomPage 录音→播放→来电链路；iOS/Android 实机要求仍如上，不把 HTML 交互证明替代设备音频验证。
