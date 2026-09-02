
## 实施与发布记录（0.3.24+27，2026-08-31）

### R1/R2 视频预览播放与压缩产物复用
- 新增 `GalleryVideoPreviewPage`（`gallery_video_preview.dart`）：图片页
  点击视频进入，播放**压缩产物临时文件**（与发送复用同一份，不二次转码）；
  播放/暂停、右下角“选择/已选择”胶囊；播放器初始化失败（冷门容器）
  降级为静态缩略图+可选可发。
- 压缩产物缓存：`DeviceGalleryPager._compressedVideoFiles` 按 asset.id
  缓存压缩文件，`GalleryPhoto.compressedPreviewFile` 注入预览页。
- 策略固化：默认 MP4(H.264/AAC) 480p；原图模式原样发送、>20MB 拦截；
  压缩失败回退原文件且 ≤20MB 兜底。
- 新增依赖 `video_player`（pub add 解析 2.14.0，pubspec 显式记录）。

### R4 视频消息视觉与播放
- `MessageTypes.Video → RoomMessageKind.video`（不再降级 file）；
  `messageBubbleIsDecorated(video/image) = false`：视频与图片消息均
  **无气泡底衬**（视频不再出现绿色气泡）。
- 新增 `WeChatCallBubble` 同族的 `VideoMessageCard`（无气泡媒体卡：
  深色缩略区+白色描边播放钮+时长角标）与 `VideoViewerPage` 全屏播放
  （字节→临时文件→file 播放器，播放/暂停/进度/时长，Wakelock 常亮）。
- 发送链路为视频附带 `info.duration`（毫秒），接收端展示时长角标。
- 会话列表摘要 m.video → `[视频]`（已有映射，回归确认）。

### 测试与发布
- 全量 `flutter test` **477 passed**、`flutter analyze` 0 issue。
- 三架构加固 APK（arm64 `cd8570f3…`、arm32 `0d312977…`、
  x86_64 `773f9953…`）分块上传，服务器哈希一致，`latest-*.apk` 刷新，
  外网抽测 206。
- 更新设置发布（幂等键 `app-update-publish-0.3.24-20260901`）：
  `latest_version=0.3.24`、`latest_build=2027`（arm64 清单值方案），
  0.3.21~0.3.23 客户端（语义比较）启动即弹“发现新版本 0.3.24”。
- 模拟器：x86_64 包安装成功、`versionName=0.3.24`、启动正常。
- 真机回归项（R3）：READ_MEDIA_VIDEO 授权后各品牌相册视频可见可选、
  转码耗时与发热、MKV/AVI 兼容性（播放允许降级为仅发送）。

## 消息交互七项修复（转发选人页/气泡菜单等，2026-08-31 追加）

1. **长按触觉**：`_showMessageActions` 首行 `HapticFeedback.mediumImpact()`，
   长按瞬间即触发系统震动。
2. **气泡锚定菜单**：新增 `MessageBubbleMenu`（深色半透明圆角容器，
   横向图标+白字项、细白分隔线、每行最多 4 项自动换行）；消息行包
   `CompositedTransformTarget`（LayerLink），菜单经
   `CompositedTransformFollower` 出现在**气泡正上方**——自己消息右对齐、
   对方消息左对齐（屏幕内不自溢出）；点击空白处关闭。
   **彻底移除**原底部 `MessageActionSheet` 弹层（仅保留其
   `MessageSelectionBar` 多选栏组件）。
3. **复制第一位**：`MessageAction.copy` 新增；策略对 text 消息注入 copy；
   展示顺序经 `MessageActionPolicy.ordered`（copy→forward→addToEmoji→
   reply→reminder→recall→multiSelect→deleteLocal）归一化；
   处理为 `Clipboard.setData` + “已复制”提示。
4. **转发统一跳转“选择聊天”页**：新增 `ChatForwardPickerPage`
   （导航右上角“多选”、第一行搜索栏、第二行“最近转发”横排头像、
   第三行起“最近聊天”列表、群聊显示“(N)人”、多选模式底部
   “发送(N)”）。图片/视频/文字/文件四类消息的长按菜单“转发”与
   多选栏“转发”统一走该页面；服务端仍走
   `interaction.forward`（加密副本）。
5. **最近转发持久化**：`RecentForwardStore`（SharedPreferences，
   最近 10 个转发目标，去重按最近使用排序）。
6. 复制动作的 `MessageAction`/policy/展示顺序均有单测
   （`message_bubble_menu_test` + `message_action_policy_test` 追加）。

发布：0.3.24 加固三架构包重新上传替换
（arm32 `91ddfd8c…`、arm64 `7d3663d5…`、x86_64 `507aacba…`），
模拟器因雷电进程退出暂未重装（安装命令已备，进程重启后执行即成功）。

## 0.3.25 消息交互七项修复发布（2026-08-31 追加）

七项修复（长按震动/气泡锚定菜单/复制居首/独立选择聊天页/页面布局/
四类消息统一转发/微信基准视觉）合入 **0.3.25+28** 加固构建：

- 三架构 APK 分块上传，服务器端 sha256 与本地一致
  （arm64 `76bfb7c0…`、arm32 `847fdf40…`、x86_64 `5b04d11d…`），
  `latest-*.apk` 别名刷新，外网抽测 206。
- 更新设置发布（幂等键 `app-update-publish-0.3.25-20260901`）：
  `latest_version=0.3.25`、`latest_build=2028`（arm64 清单值 2000+build），
  容器内外回读 PASS，更新说明含全部交互改进。
- 生效语义：0.3.21~0.3.24 客户端（语义比较）启动即弹
  “发现新版本 0.3.25”。
- 模拟器：雷电进程在本轮部署期间崩溃退出，`dnconsole launch` 重启后
  卡在启动阶段（adbd 未监听），0.3.25 x86_64 安装待模拟器恢复后执行：
  `adb install --no-streaming -r -d apps/mobile_flutter/build/app/outputs/
  flutter-apk/ChatFlow-0.3.25-x86_64.apk`（包已就绪）。
