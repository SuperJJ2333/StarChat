# “按住说话”交互修复与松手发送 — 验证证据（2026-08-31）

发布到雷电模拟器：**0.3.17+20**（release 签名，x86_64 分包）。

## 需求与修复

### 1. 覆盖层渲染时机（按下即现）

- **根因**：`RoomPage` 覆盖层的挂载条件读 `voiceRecording.state`，但 RoomPage 自身没有监听控制器；`start()` 的 `notifyListeners` 只重建了按钮局部，覆盖层要等 1 秒计时器 tick 或录音启动回调触发 `setState` 后才出现（约 1~2 秒延迟）。
- **修复**：覆盖层改为常驻 `Positioned.fill` + `ListenableBuilder(listenable: voiceRecording)` 驱动显隐——按下瞬间 `start()` 通知监听器，同帧渲染，不等待音频启动。

### 2. 按钮反馈（震动 + 动效）

- 按下瞬间 `HapticFeedback.mediumImpact()`（不等待录音启动结果）。
- 按住期间按钮背景加深（`systemGrey4`）+ `AnimatedScale` 0.97 按压动效，文案切换为「松开发送」（滑到取消区为「松开取消」红底白字）。

### 3. 目标区改圆形 + 高亮 + 震动

- 左「取消」、右「滑到这里 转文字」改为 **96×96 圆形**（`BoxShape.circle`，测试断言形状）。
- 中部新增「松手发送」胶囊横条。
- 滑入高亮：取消=红色填充+放大 1.08+红色光晕描边；转文字=品牌绿；松手发送=品牌绿胶囊。未武装态为半透明灰。
- 滑入/切换目标区瞬间 `HapticFeedback.selectionClick()` 震动。

### 4. 命中判定重写（此前滑到圆点经常不触发的根因）

- 旧逻辑按 `page.height * 0.86` 判定按钮带，与覆盖层实际绘制位置（距底 150~246px）不匹配；且「上滑 ≥60 取消」优先级最高，滑向右圆途中必经上滑位移，转文字永远无法命中。
- 新逻辑：命中带=距屏幕底部 [110, 330]（放宽覆盖安全区差异），带内按水平位置判定——左圆区（dx ≤ 12+96）→取消、右圆区→转文字、中部→松手发送；带外上滑 ≥60 保留快捷取消；**带内判定优先于上滑**。
- 控制器与覆盖层共用几何常量（`targetEdgeInset`/`targetRowHeight`/`targetRowBottomInset`），画在哪里就能在哪里触发。
- 松手语义：左圆松手→取消录音并删除文件；右圆松手→转文字；中部/任意非取消区松手→发送。

### 5. 「未能识别语音内容，已取消/停止发送」修复

- 识别器 `stop()` 增加有界等待（≤3s，100ms 轮询）：系统 `done` 回调晚于 `stop()` 时不再返回空串；能力不可用时立即返回。
- 转文字松手新流程：识别成功→发送文字（删除原音频）；识别为空/失败→**降级发送原语音**并提示「未识别到文字，已发送原语音」，任何情况下不再丢弃录音、不再出现阻断性错误提示。
- 短于 1 秒仍按无效录音取消（不变）。

## 测试证据

- `flutter analyze`：No issues found。
- 全量 `flutter test`：**445 passed**（含更新后的 24 项语音交互聚焦用例）。
- 新增/更新用例：右圆带内命中优先于上滑（回归根因 2）、中部带武装 send、松手发送 release 进 preview、离开命中带回 recording、圆形形状断言（`BoxShape.circle` + 正方形尺寸）、松手发送高亮与提示文案、小幅上滑落带不再误触取消（composer 集成）。
- 视觉验收（judge 两轮，终轮全过）：四种状态渲染截图见
  `artifacts/2026-08-31/voice-hold-to-talk/overlay_{recording,cancel-armed,send-armed,text-armed}.png`。
  首轮唯一缺陷：秒数文字 `systemGrey4` 对比度过低 → 改为 75% 不透明白后复审通过。

## 模拟器部署

- 设备：`emulator-5554`（雷电，x86_64）。
- APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-x86_64-release.apk`
  （SHA256 前 16 位 `d903b40a305f4751`，59.1MB，构建于 2026-08-31 20:08）。
- `adb install -r -d` Success；设备 `versionName=0.3.17`，`lastUpdateTime=2026-08-31 20:08:54`；启动正常（pid 存活、无 FATAL）。

## 已知边界

- 模拟器无登录凭据（历史验证文档同样确认），端到端录音/识别链路需用真实账号在会话页手工验证；交互逻辑与几何判定已由 24 项 widget 用例覆盖。
- 语音识别依赖系统 ASR（`speech_to_text`）：无 Google 识别服务的设备上转文字松手会自动降级为发送原语音，不会报错。
