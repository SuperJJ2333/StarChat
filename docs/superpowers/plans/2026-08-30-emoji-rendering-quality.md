# 2026-08-30 移动端 IM Emoji 显示与使用体验优化

## 范围与目标

- 超级表情（动态emoji）消息：修复边缘毛刺，并在消息中展示发送者头像与昵称/备注。
- 普通emoji：基于 microsoft/fluentui-emoji 以矢量（SVG）渲染，高 DPI 下清晰锐利，无卡顿。
- 不改变现有发送链路（表情仍以 Unicode 字符进入加密文本消息；我的表情仍为 E2EE 表情仓库媒体消息）。

## 根因分析：动态emoji毛刺

证据链（`scripts/prepare_fluent_emojis.py` + 运行时渲染代码）：

1. 源资产为 Tarikul-Islam-Anik/Animated-Fluent-Emojis 的 APNG，实测 `Face with Tears of Joy.png` 为 **256×256、48 帧**。
2. 构建脚本 `apng_to_gif(data, out_path, size=72)` 将源帧 LANCZOS 缩至 **72×72** 再编码 GIF。
3. GIF 仅支持 **256 色调色板 + 1-bit 二值透明**：边缘像素要么全不透明要么全透明，源图中抗锯齿的半透明过渡被二值化，边缘天然存在硬锯齿。
4. 消息内渲染（`matrix_home_page.dart`）单枚 96 逻辑像素；3x 屏 = **288 物理像素**，对 72px 位图做 ~4× 上采样，配合 `FilterQuality.medium`（双线性）进一步放大锯齿 → 肉眼可见毛刺。

结论：毛刺 = “低分辨率源 × 上采样 × 二值透明 alpha”三因叠加，非运行时渲染参数单点问题。

## 方案

### A. 超级表情画质修复

- `scripts/prepare_fluent_emojis.py` 改为输出 **256×256 animated WebP**（`quality≈60`、`alpha_quality=100`，8-bit 平滑 alpha；与源同分辨率，零下采样）。
- Flutter 原生支持 Animated WebP 解码（`Image`/`Image.asset` 直接播放），无需新依赖；单枚 ~240KB（48 帧全唯一帧，体积由帧数主导），54 枚总计 ~13MB（现 72px GIF 为 9.3MB，质量差 3.5× 分辨率 + 平滑 alpha）。
- 渲染：消息内 `Image.asset` 尺寸维持 96/64 逻辑像素不变（≤ 源分辨率，任何 DPR 下不再放大），`filterQuality` 升为 `high`（cubic）。
- 资产清理：脚本删除旧 `assets/emoji/*.gif`，`pubspec.yaml` 改为目录声明 `assets/emoji/`、`assets/emoji_vector/`。

### B. 超级表情消息展示头像 + 昵称/备注

现状：纯动效emoji消息在 `_messageRow` 中仅渲染无气泡的表情行，无头像/昵称，无法识别来源。

方案：新增 `lib/ui/chat/super_emoji_message.dart`（`SuperEmojiMessage`）：表情行作为 `WeChatMessageBubble(decorateContent: false)` 的 content 复用 —— 头像槽位（含点击/双击戳一戳/长按@）、 incoming 昵称/备注（`contactsByMatrixId` 备注优先）、方向对齐、发送状态（转圈/失败重试）、长按消息操作与普通消息完全一致，保证与现有布局一致。`RoomPage._messageRow` 替换原 Padding+Row 分支。

### C. 普通emoji矢量化（microsoft/fluentui-emoji）

- 新脚本 `scripts/prepare_fluent_vector_emojis.py`：拉取 microsoft/fluentui-emoji（GitHub tree API 定位 + jsDelivr/raw 下载）**Color 风格 SVG**；有肤色变体的取 `Default`。精选 ~125 枚常用表情（含 54 枚动效emoji对应的 Unicode 字符 + 补充表情/手势/爱心/符号/动物/食物/物品），生成：
  - `apps/mobile_flutter/assets/emoji_vector/<slug>.svg`（合计 < 1MB）
  - `apps/mobile_flutter/lib/features/emoji/fluent_vector_emoji_catalog.dart`（含 `vectorEmojiByChar`，匹配时剥离 VS16 `\uFE0F`）
- 新组件 `lib/ui/chat/emoji_text.dart`（`EmojiText`）：按 `characters` 字素扫描文本，已知 emoji 用 `WidgetSpan` + `SvgPicture.asset`（`PlaceholderAlignment.middle`，字号 ×1.18）替换；未命中任何 emoji 时零开销回退 `Text`。flutter_svg 全局缓存解析结果（`svg.cache`，按 loader 复用 `PictureInfo`），同 emoji 多处出现不重复解析。
- 使用点：`RoomPage._messageContent` 的 `RoomMessageKind.text => Text(message.text)` 改为 `EmojiText`（私聊+群聊共用该渲染路径）。
- 表情面板 `ChatEmojiPanel` 新增 “emoji” 页签：矢量静态表情网格（GridView.builder 惰性构建），点击经原 `_insertEmoji` 插入 Unicode 字符，发送链路不变；“全部”（动效）与“我的表情”页签行为不变。

### D. 性能与画质平衡

- 矢量：SVG 按 widget 尺寸 × DPR 栅格化，任意分辨率原生锐利；解析结果全局 LRU 缓存；网格惰性构建；单枚 SVG 3~15KB，解析亚毫秒级。滑动/输入路径与现状相同（纯文本消息仍走 `Text` 快速路径）。
- 动效：WebP 8-bit alpha + 源分辨率，渲染尺寸不放大；`gaplessPlayback` 保持。
- 回退：不在矢量目录中的 emoji 字符继续由系统字体渲染，不丢字符、不阻塞。

## 测试（先行红 → 绿）

1. `test/features/emoji/fluent_emoji_message_test.dart`：资产断言改为 `.webp`；新增“256px 源不再被放大”的目录级断言（catalog asset 全部为 webp）。
2. `test/features/emoji/fluent_vector_emoji_catalog_test.dart`（新）：目录唯一性、VS16 剥离查找、SVG 资产存在（根 bundle 可加载）。
3. `test/ui/emoji_text_test.dart`（新）：纯文本回退 `Text`；已知 emoji 生成 `WidgetSpan`+Svg；中英混排正确切分；VS16 变体命中。
4. `test/ui/super_emoji_message_test.dart`（新）：单枚/多枚渲染 96/64、`filterQuality.high`、incoming 展示昵称+头像槽、outgoing 不展示昵称、长按回调透传。
5. `test/ui/chat_emoji_panel_test.dart`：新增 “emoji” 页签渲染矢量网格、点选回传 Unicode。

## 验收对照

- 动态表情边缘平滑无毛刺：256px 8-bit alpha 源 + 不放大渲染（代码评审 + 资产规格断言）。
- 消息可见发送者头像与昵称/备注：`SuperEmojiMessage` 复用 `WeChatMessageBubble` 槽位，widget 测试断言。
- 普通emoji高DPI矢量渲染：SVG 栅格化 + `EmojiText` 测试。
- 性能：矢量解析缓存 + 网格惰性 + 快速路径回退；目标中端机（Redmi Note 级）消息列表滑动 60fps 无新增掉帧、面板打开 <300ms（以现有设备实测为准）。
- 功能与交互流程不变：发送仍为加密文本 Unicode；我的表情链路、面板点选行为、长按操作均保持。

## 验证证据

- `flutter analyze`、`flutter test`（emoji 相关全量）、`scripts/verify.ps1` 输出存档至 `docs/verification/2026-08-30-emoji-rendering-quality/`。
