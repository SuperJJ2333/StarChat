# Fluent 动效表情 / 微信式图片多选发送 — 验证证据（2026-08-30）

## 1. Emoji 方案替换（Animated-Fluent-Emojis）

- 弃用 `emoji_picker_flutter`（unicode 选择器）依赖与实现，依赖已从 pubspec 移除。
- 新增 `scripts/prepare_fluent_emojis.py` 流水线：从 Animated-Fluent-Emojis 仓库（api.github.com 文件树 + codeload 整包，jsDelivr 对该超大仓库返回 403 不可用）提取策划子集 **54 个动效表情**，Pillow 解 APNG 帧缩放至 72px 编码为 GIF（Flutter 原生支持 GIF 动画，零额外依赖），输出 `apps/mobile_flutter/assets/emoji/*.gif`（共 9.3MB）并生成 `lib/features/emoji/fluent_emoji_catalog.dart`（名称/Unicode 字符/资产三元组）。
- 表情面板重写（`chat_emoji_panel.dart`）：「全部」= Fluent GIF 网格（8 列、`gaplessPlayback` 复用帧、懒构建）＋「我的表情」（自定义表情保留）。点选表情插入 Unicode 字符进加密文本消息 —— **发送路径与普通文本完全一致，无媒体上传**，保证可感知发送速度。
- 性能措施：GIF 预缩放 72px（解码帧小）、按网格懒构建（离屏即释放）、内存图片缓存复用；选中即插入字符，无卡顿路径。
- 消息兼容性：消息体为 Unicode 文本，未安装新字体的旧端仍可正常显示（系统 emoji 渲染）。

## 2. 图片发送重构（微信式多选页）

- 新增 `lib/features/matrix/image_picker_page.dart`：
  - **每行 4 张**网格（`crossAxisCount: 4`），缩略图 200px（默认压缩展示）；
  - 左上角圆点勾选（选中 = 品牌绿底白勾 + 120ms 缩放动画 + 勾选序即发送顺序），点缩略图或圆点均可切换；
  - **最多 9 张**：超限时拒绝勾选并红字提示「最多选择9张图片」；
  - 底部栏左下角「**原图**」开关（CupertinoSwitch，默认关闭）——关闭发送 1280px/80% 压缩图，打开逐张发送原图；
  - 「发送(N)」按钮随选择数量激活/更新。
- 新增 `device_gallery_source.dart`（photo_manager ^3.12）：权限申请、按 `onlyAll` 相册取最近 600 张图片、缩略图/压缩图/原图三种解码。Android `READ_MEDIA_IMAGES` 与 iOS `NSPhotoLibraryUsageDescription` 权限已有。
- 房间页接线：「更多 → 图片」打开选择页 → 逐张加密上传（进度提示 i/N），失败提示与忙碌态复用既有机制。纯逻辑 `GallerySelection`（上限/顺序/切换）独立可测。

## 3. UI/交互规范落实

- 布局、配色全部走 WeChatTokens（品牌绿、danger 红、分割线灰），图标 Cupertino 风格；勾选/取消动效 ≤120ms；列表懒构建 + `gaplessPlayback` 保帧率；`prefers-reduced-motion` 无关（无长动画）。Android/iOS 行为一致（同一 Flutter 页面），网格自适应屏宽。

## 4. 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **374 passed**（新增：图片选择页 4 项 + 表情面板重写 3 项） |
| 表情资产 | 54 个 GIF 全部打包（AssetManifest 含 108 条 emoji 记录） |
| 生产发布 | `ChatFlow-0.3.2` 三架构包上线（arm64 SHA256 `B1F4CCE4…`，58.8MB，含表情资产 +9MB）；0.3.1 包下线；域名验证 PASS |
| 更新推送 | 已发布 `latest=0.3.2/build 5, min_supported=3`：0.3.1 用户弹可忽略更新，build≤2 强制更新 |

## 5. 遗留事项（非阻塞）

- 表情子集为策划的 54 个高频表情；如需扩充，将条目加入 `scripts/prepare_fluent_emojis.py` 的 CURATED 表后重跑流水线即可。
- 动效表情在消息气泡内以 Unicode（系统字体）呈现，保证旧端兼容；如需"全端统一 Fluent 渲染"，可在后续版本将消息内已知表情码替换为内联 GIF（涉及富文本渲染，独立迭代）。
