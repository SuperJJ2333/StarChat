# 2234 聊天时间顺序回归修复

> For agentic workers: use executing-plans for bounded inline implementation, with specification review before quality/security review.

**Goal:** 冷启动默认展示最新消息，上滑按时间展示历史及失败消息，移除本机保存提示。

**Architecture:** 展示数据在截取窗口前按消息时间稳定排序；同时间保留输入次序。SDK 原始事件、数据库索引和分页游标不变。窗口外的旧待发送记录仍保留，进入相应时间段才显示。

**Tech Stack:** Flutter/Dart，Matrix SDK，现有消息 viewport/outbox。

**Spec:** 用户 2026-10-25 的三项缺陷及“9 月 27 日消息没有失败标记”补充；延续 2026-10-21-timeline-scroll-position.md 的锚点契约及 2026-10-16-interactive-cache-startup.md 的离线输入契约。产品约束见 ../specs/2026-08-12-starchat-product-modernization-design.md。

## 边界与所有权

- 本任务独占 matrix_e2ee_client.dart、room_timeline_controller.dart、matrix_room_timeline_adapter.dart、room_page.dart、timeline_scroll_anchor.dart、展示排序辅助文件及直接回归测试。
- 不修改金融、鉴权、加密、依赖锁、SDK 存储/分页、版本号或既有工件身份。
- 保留主工作树所有既有改动；在 codex/ios2234-timeline-order-20261025 上实施。

## 审查重点

- 普通旧消息晚恢复；同时间稳定；冷启动最新 40 条截取发生在排序之后。
- 历史锚点、200 条上限、SDK 游标不受展示排序影响。
- 旧失败记录不提前进入最新窗口，翻到原时间段可见，仍可重试。
- 确认回执去重和服务端时间权威不变。
- 移除提示后离线文本仍持久化，恢复派发守卫不变。
- 移除提示后，冷启动就绪/输入区高度变化保持实际阅读行；持续拖动和惯性不取消，坐标补偿不计入用户滚动。

## 执行

1. [x] 在 matrix_room_timeline_adapter_test.dart 验证普通旧消息落入正确历史位置、最新窗口与原始 SDK 次序；在 room_timeline_controller_test.dart 验证非单调时间展示及失败记录窗口；在 app_home_interactive_local_test.dart 验证提示消失但离线文本仍落盘。运行 focused 测试，记录真实 RED。
2. [x] 添加稳定时间排序函数，仅用于投影；过滤窗口外的 pending 合并，统一恢复入口；删除 RoomPage 提示组件。运行相同 focused 测试，取得 GREEN。
3. [x] 运行相邻历史、锚点、outbox 测试及 flutter analyze；规格审查后质量/安全审查。修复发现后冻结输入并运行 Flutter 完整门禁。完整运行的 4 项私有 Fake 缺接口失败，补齐后整文件 4 PASS，输入比对后复用其余通过结果，保留原失败退出码。
4. [x] 检查 scripts/verify.ps1 环境及输入，按移动交付规则复用未变更服务端门禁，补齐本次移动端验证。记录命令、退出码、计数及源码 hash；iOS 构建/设备验收独立标记，禁止声称尚未测试的设备结果。
