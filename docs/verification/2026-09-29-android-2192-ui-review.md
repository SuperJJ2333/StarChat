# Android 2192 页面设计与功能验收

日期：2026-09-29（Asia/Hong_Kong）。本页记录已批准的钱包 A 版、搜索头像、转让群主及转发头像的 HTML demo 与 Flutter 对照；最终 Debug 安装和模拟器交互另记任务台账。

## 可视化页面

本地入口为 `frontend/index.html`，或运行 `npm run serve` 后访问以下屏幕 ID：

| 需求 | Catalog screen ID | HTML / Flutter 实现 | 状态 |
| --- | --- | --- | --- |
| 钱包白色大余额卡、绑定警示与卡片、未绑定禁用充值和提现 | `wallet-home-unbound` | `frontend/src/screens/wallet-binding.js` / `apps/mobile_flutter/lib/features/wallet/manual_wallet_page.dart` | HTML 测试通过；Flutter 聚焦测试通过 |
| 全局搜索群聊与消息头像 | `chat-search-global-results` | `frontend/src/screens/messaging.js` / 全局搜索结果页 | HTML 测试通过；Flutter 聚焦测试通过 |
| 群主转让头像、搜索、待核对与完成返回 | `chat-group-management-transfer-members`、`chat-group-management-transfer-pending`、`chat-group-management-transfer-completed` | `frontend/src/screens/messaging.js` / 群主管理页面 | HTML 测试通过；Flutter 聚焦测试通过 |
| 转发目标头像完整显示 | `chat-forward-background`，点击“转发”查看目标选择 | `frontend/src/screens/messaging.js` / 转发目标弹层 | HTML 测试通过；Flutter 聚焦测试通过 |

设计使用 `frontend/src/styles/primitives.css` 的语义颜色、间距、圆角和触控尺寸；组件映射见 `packages/ui-contracts/changliao-component-registry.json` 的 `android2191Followup20260929`。Figma 已退役：本次变更仅更新 HTML demo（`frontend/index.html`）。

## 验证

- HTML demo 变更提交：`90d0cd85`。`npm run verify` 退出 0：Node 测试 316/316、Browser smoke PASS、注册屏幕截图 438/438。两张不再注册的旧 PNG 已移除；新注册与此前缺失的设计截图已补齐。
- `python scripts/verify_ui_contract.py` 退出 0：32 个组件、438 个屏幕，注册表漂移检查通过。
- 本任务聚焦 Flutter 钱包、全局搜索、转让和转发测试的 RED/GREEN 证据见 `docs/verification/artifacts/2026-09-29/android-2191-followup/` 对应模块记录。模拟器最终包尚待安装时，本记录不宣称设备验收完成。

截图可直接查看 `frontend/artifacts/screenshots/wallet-home-unbound.png`、`chat-search-global-results.png` 和 `chat-group-management-transfer-members.png`。本地 demo 为静态示例数据；真实保存、权限、错误和成功状态由 Flutter 与业务 API/Matrix 路径验收。
