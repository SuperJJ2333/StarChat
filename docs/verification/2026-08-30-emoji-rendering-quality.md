# Emoji 显示与体验优化 — 验证证据（2026-08-30）

需求：①动态emoji（超级表情）修复毛刺并在消息中展示发送者头像/昵称备注；②普通emoji基于 microsoft/fluentui-emoji 矢量化渲染，高DPI清晰、操作无卡顿；③功能与交互流程不变。计划：`docs/superpowers/plans/2026-08-30-emoji-rendering-quality.md`。

## 1. 毛刺根因（证据链）

1. 源资产 Animated-Fluent-Emojis APNG 实测 **256×256、48 帧**（`Emojis/Smilies/Face with Tears of Joy.png`，745KB）。
2. 旧构建脚本 `apng_to_gif(..., size=72)` 将源帧缩至 **72×72 GIF**。
3. GIF 为 **256 色调色板 + 1-bit 二值透明**：源图边缘抗锯齿的半透明像素被二值化，边缘天然硬锯齿。
4. 消息内渲染 96 逻辑像素，3x 屏 = **288 物理像素**，72px 位图被 ~4× 上采样，`FilterQuality.medium`（双线性）进一步放大锯齿。

结论：毛刺 = 低分辨率源 × 上采样 × 二值透明 alpha 三因叠加。

## 2. 修复实现

### 超级表情（动态emoji）
- `scripts/prepare_fluent_emojis.py` 重写：下载 APNG 后**保留 256px 源分辨率、全部帧**，编码 **animated WebP（quality=60、alpha_quality=100，8-bit 平滑 alpha）**；Flutter 原生解码 animated WebP，零新依赖。56 枚共 16.5MB（旧 72px GIF 为 54 枚 9.3MB，分辨率提升 3.5×）。
- 脚本具备断点续跑（已存在且可完整解码的输出跳过）、GitHub tree API 优先 + jsDelivr/raw 回退、并发下载；目录表（含 `fluentEmojiByChar`、`fluentEmojisInMessage` 助手）由脚本完整生成，修复了旧脚本对 `Smiling Face with Heart-Eyes.png`/`Upside-Down Face.png`（文件名含连字符）静默漏采的缺陷（54 → 56 枚）。
- `SuperEmojiMessage`（`lib/ui/chat/super_emoji_message.dart`）：表情行作为 `WeChatMessageBubble(decorateContent: false)` 的 content 复用 —— 头像槽位（点击开资料卡、双击戳一戳、长按@）、incoming 昵称/备注（联系人备注优先）、方向对齐、发送/失败状态、长按消息操作菜单与普通消息完全一致；渲染尺寸维持 96/64 逻辑像素（≤源分辨率，任何 DPR 不放大），`filterQuality` 升为 `high`。
- `RoomPage._messageRow`（私聊+群聊统一渲染路径）以 `SuperEmojiMessage` 替换原无头像的 Padding+Row 分支。

### 普通emoji矢量化（microsoft/fluentui-emoji）
- 新脚本 `scripts/prepare_fluent_vector_emojis.py`：GitHub tree 定位 + jsDelivr/raw 下载 **Color 风格 SVG**（人物类取 Default 肤色），225 枚共 4.0MB → `assets/emoji_vector/`，生成 `fluent_vector_emoji_catalog.dart`（225 项，覆盖全部 56 个动效字符 + 常用补充；查找时剥离 VS16，`❤️`→`❤`）。
- `EmojiText`（`lib/ui/chat/emoji_text.dart`）：按 `characters` 字素切分文本，已知 emoji 以 `WidgetSpan`+`SvgPicture.asset`（middle 对齐，字号×1.18）内联矢量渲染；**无命中时零开销回退 `Text`**（纯文本消息不进富文本管线）。flutter_svg `SvgAssetLoader` 按值相等命中全局缓存，重复构建不重复解析。
- 接入点：`_messageContent` 的 `RoomMessageKind.text => EmojiText(message.text)`；表情面板新增 “emoji” 页签（`_VectorEmojiGrid`，GridView 惰性构建）。
- 发送链路不变：面板点选/键盘输入仍只插入 Unicode 字符进加密文本消息；“全部”（动效）与“我的表情”（E2EE 表情仓库）行为未改。

## 3. 测试（先红后绿）

| 阶段 | 证据 |
| --- | --- |
| 红 | 旧目录表指向 `.gif` 时新断言按预期失败：`Expected 'assets/emoji/joy.webp' / Actual 'assets/emoji/joy.gif'`；`Expected a string ending with '.webp' / Actual 'assets/emoji/angry.gif'`。日志：`docs/verification/artifacts/2026-08-30/emoji-rendering/red-phase-fluent-emoji-test.log` |
| 绿 | `flutter test` **407 项全部通过**（新增 17 项：矢量目录 5、EmojiText 5、SuperEmojiMessage 6、面板矢量页签 1；动效目录测试含“全部资产为 ≥192px WebP”逐枚解码断言，实际 256×256、49 枚多帧） |
| 静态检查 | `flutter analyze --no-pub`：**No issues found** |
| 仓库门禁 | `pwsh -NoProfile -File scripts/verify.ps1`：**exit 0**（仓库策略、模板、Matrix Bot、business-api/worker pytest、Flutter 边界、Alembic 迁移、OpenAPI 漂移、Compose 渲染全部 PASS） |

关键断言对应验收：
- 边缘平滑无毛刺 → `animated assets are high-resolution WebP with smooth alpha`（56 枚逐枚解码断言分辨率）+ `filterQuality.high` + 渲染尺寸 ≤ 源分辨率（`single super emoji renders 96px with high quality filter`）。
- 消息可见发送者头像与昵称/备注 → `incoming super emoji shows avatar slot and sender name`、`outgoing super emoji shows own avatar without sender name`、`long press on the emoji row is forwarded`、`super emoji content is rendered without a bubble decoration`。
- 普通emoji矢量高DPI → `known emoji is replaced by an inline vector glyph`、`emoji with presentation selector resolves to the vector set`、`unknown emoji chars fall back to system text rendering`（目录外字符不丢字）。
- 性能 → 纯文本快速路径（`plain text renders through the fast Text path`）+ 网格惰性构建 + flutter_svg 全局缓存；中端机滑动/面板打开建议按 60fps 目标做一次真机抽查（本次自动化覆盖正确性与管线开销路径）。

## 4. 资产规格抽查

- `assets/emoji/`：56 个 .webp，全部 256×256，49 枚多帧动画，共 16.5MB；旧 .gif 已由脚本清理（pubspec 改为目录声明 `assets/emoji/`、`assets/emoji_vector/`）。
- `assets/emoji_vector/`：225 个 .svg（fluentui-emoji Color/Default），共 4.0MB。flutter_svg 对其 `<filter>` 元素忽略并告警（`unhandled element <filter/>`），不影响字形渲染，为 flutter_svg 已知能力边界。

## 5. 环境修复记录（与本需求无直接关系但为验证所必需）

- 用户级环境变量 `FLUTTER_STORAGE_BASE_URL`、`PUB_HOSTED_URL` 的值含字面引号（`"https://..."`），导致 flutter.bat/dart 工具链解析失败；已改写为无引号值（`setx` 级修复）。
- 仓库根新增 `analysis_options.yaml`，将 `docs/**`、`.worktrees/**` 排除出分析上下文 —— 此前 `docs/verification/artifacts/2026-08-29/` 内上批会话遗留的整份应用副本（baseline/rollback-copy）使 `flutter analyze` 报 2347 个无关错误。副本未删除、仅排除出分析范围。

## 6. 变更文件

- 脚本：`scripts/prepare_fluent_emojis.py`（重写）、`scripts/prepare_fluent_vector_emojis.py`（新增）
- 生成物：`assets/emoji/*.webp`（56）、`assets/emoji_vector/*.svg`（225）、`lib/features/emoji/fluent_emoji_catalog.dart`、`lib/features/emoji/fluent_vector_emoji_catalog.dart`
- 组件：`lib/ui/chat/emoji_text.dart`、`lib/ui/chat/super_emoji_message.dart`（新增）；`lib/ui/chat/chat_emoji_panel.dart`、`lib/features/matrix/matrix_home_page.dart`、`pubspec.yaml`（修改）
- 测试：`test/ui/emoji_text_test.dart`、`test/ui/super_emoji_message_test.dart`、`test/features/emoji/fluent_vector_emoji_catalog_test.dart`（新增）；`test/features/emoji/fluent_emoji_message_test.dart`、`test/ui/chat_emoji_panel_test.dart`（更新）
- 仓库：`analysis_options.yaml`（新增）
