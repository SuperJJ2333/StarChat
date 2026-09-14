# 2026-09-14 合并保留性审计与 Mi 6 Debug 2108 修复交付

## 背景

用户质询合并是否保留了各 codex 流的优化。逐文件审计（merge 双亲 18e80891 / d0c62f94 与 HEAD 三方对比）确认三处 main 侧用户验收内容在冲突解决时被分支版本覆盖：

1. **全部账单/账单详情重设计**（金额右对齐、状态、日历日期、`_billTitle` 对手方后缀、`formatLedgerRowAmount`；`ledger_pages.dart` 432 行 + 测试 88 行 + 前端 `finance.js` hero/交易对方行 + registry `group-member-picker`/`shared-official-name` 注册与 30 组件契约）。
2. **成熟拍一拍限流**（`NudgeRateLimiter.shared` reservation/release 预占模式、sessionEpoch/sender 竞态保护、rootOverlay `WeChatToast`）此前被简版实例级限流替代。
3. 组件注册表屏幕计数与 `test_ui_component_registry.py` 契约（30 组件 / 369 screens，含 support 身份 demo 增量）。

确认保留良好的优化：媒体缓存四件套（图片/缩略图/视频海报/预览缓存）、`media_load_scheduler`、`media_memory_budget`、`gif_image_policy`、`MomentPreviewCache.forApi`（含并发预取+TTL）、图片编辑器 history/undo 重构、群成员选择器、bounded history navigation。分支提交全部可从 HEAD 追溯（六分支 tip 均 merge-base --is-ancestor 通过）。

## 修复（commit 9f342beb）

- `ledger_pages.dart` 与测试整体恢复 P1（18e80891，即 Mi 6 2105/2106 验收版，自带 identityCache）。
- `room_page.dart` 恢复 `NudgeRateLimiter` 接线 + `_showNudgeToast`（rootOverlay + WeChatToast + `room-nudge-toast` Key）+ dispose 清理；移除简版静态 Map 限流。
- 前端恢复 P1 `finance.js`；`ledger-layout.test.mjs` 断言对齐 P1 结构（hero/交易对方/复制账单ID/无合计行）；image-editor 马赛克取色改 hex 形式满足 token 契约扫描；测试补 `getComputedStyle` stub。
- registry 恢复 P1 两组件并保留 `supportIdentities` prop；契约验证 `PASS (30 components, 369 screens)`。
- 验证：Flutter 全量 2663 通过；前端 209 通过；registry 3 通过。

## Mi 6 Debug 2108

- 同 android-apk-rebuild 固定流程（ARM64 debug、三项 HTTPS dart-define、Apktool 2.12.1、zipalign 36.0.0 `-P 16 -f 4`、固定证书 `75b31c66…`）。
- SHA256：源 `7D7B32C0` 之前另有记录，最终重建 `EE0025C5DD6F0A4CFE8B41746C0C87433DB3EA2AB150196F80E69305C3BFCD78`；Mi 6 root 覆盖安装 Success，读回 2108/0.3.88-debug，拉回 base.apk 哈希一致，已启动。
