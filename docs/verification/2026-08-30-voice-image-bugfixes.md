# 三项 IM 体验 Bug 修复 — 验证证据（2026-08-30）

范围：①按住说话语音交互重构；②语音气泡样式修正；③图片加载导致滑动抽动。发布：**0.3.8+11**。

## 1. 语音消息发送（按住说话）

原状：麦克风按钮弹出两步式"录音→预览确认"弹窗（VoiceComposer），不符合按住即录、松手即发的交互预期。

重构后（微信式内联语音）：
- 点击麦克风按钮 → 输入框原位替换为"按住说话"按钮（`ComposerPanel.voice`），麦克风键切换为键盘键可退回文本输入（`WeChatComposer.voiceField` 槽位）。
- **按住**开始持续录音（`voice_recording_controller` 状态机 + `MediaMessageService` AAC 录制）；计时由控制器内部注入时钟计算（修复墙钟计时不稳）。
- 录音中显示**全屏毛玻璃覆盖层**（`VoiceRecordingOverlay`：BackdropFilter 高斯模糊 + 半透明底色 + `IgnorePointer` 不拦截手势）：顶部"取消"区域、中央麦克风指示、"手指上滑，取消录音"、已录秒数 `n″/60″`。
- **上滑 ≥60px** 武装取消（取消区红色高亮"松开手指，取消发送"），原地松开 → **直接加密发送**；不足 1 秒视为无效自动作废。
- **60 秒上限**：页内 Timer 到点自动停止并按正常松开发送；控制器层同时钳制时长 ≤60s。
- 旧弹窗链路（`voice_composer.dart`、`_showVoice`）删除。

## 2. 语音气泡样式

根因：`_messageRow` 渲染 `WeChatMessageBubble` 时仅红包/转账去底衬，语音消息得到"白色气泡垫绿色气泡"。修复：抽取 `messageBubbleIsDecorated(kind)`（conversation_presentation.dart）并排除 `voice`，语音消息现渲染为纯绿色气泡（头像/昵称/长按操作不变）。

## 3. 图片滑动抽动

根因（两个叠加）：
1. 列表为 `reverse` 懒构建 ListView，图片行滚出视口即销毁 State，再次滑入重新解密/读盘（`initState → load()`）；
2. 占位 160×120，加载完成后 `Image.memory` 仅固定宽、高按原图比例展开 → 行高突变，列表锚点跳变 → 无法继续下滑、屏幕抽动。

修复：
- 新增 `MediaMemoryCache`（会话页级内存缓存，`media_cache.dart`）：按 eventId 命中**同步渲染**（`SynchronousFuture`）、并发加载在途去重、失败可重试、LRU 上限 48 条防内存膨胀；命中返回同一字节实例，`Image.memory` 解码缓存按身份命中不重复解码。
- `EncryptedImageMessage`（迁移至 `lib/ui/chat/encrypted_media_view.dart`）：占位与成图统一为**固定 200×150 + BoxFit.cover** 缩略图（点击仍以原始字节全屏查看），消除布局跳变；`initialBytes` 参数接入页级缓存；顺带修复重试按钮 `setState` 返回 Future 的断言隐患。

## 测试（先红后绿 / 全绿）

- `media_memory_cache_test`（4 项）：命中同步且同实例、并发单次加载、失败可重试、LRU 淘汰。
- `encrypted_image_message_test`（3 项）：缓存同步渲染零加载、占位与成图同尺寸（防抖动断言）、失败重试。
- `voice_recording_overlay_test`（3 项）：毛玻璃+IgnorePointer+取消区文案、武装态红色高亮、60 秒钳制显示。
- `voice_recording_controller_test`（+1）：release 时长钳制 60s。
- `chat_composer_bar_test`（+4）：语音面板隐藏发送键、输入框被按住说话替代且提供键盘切换键、上滑取消手势路径、松开即发送手势路径。
- `conversation_presentation_test`（+1）：voice/redPacket/transfer 无底衬、text/image/file 有底衬。
- 全量：`flutter test` **424 passed**；`flutter analyze` **No issues found**。

## 发布 0.3.8+11

- 版本升级 `0.3.7+10 → 0.3.8+11`；Release 分 ABI 签名构建（arm64 SHA256 `62A9EB2AA052FE1AF0FAACDBD3A563A113AFDB5EC0F007A7506E2C69DA0B1E70`，服务端逐一比对一致）。
- 落地页下载链接指向 `ChatFlow-0.3.8-arm64.apk`。
- 更新设置发布：`latest_version=0.3.8 / latest_build=11`（幂等键 `app-update-publish-0.3.8-20260830`），`/api/v1/app-updates/latest` 确认下发。
- 外部验证 `verify_public_domains.ps1`：**20 项全 PASS**。
