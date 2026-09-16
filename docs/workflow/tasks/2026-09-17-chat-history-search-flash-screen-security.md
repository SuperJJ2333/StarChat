# 2026-09-17 聊天历史日期查询、全局搜索、闪照隐私与屏幕捕获安全（任务 A–E）

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令「修复 ChatFlow Flutter 客户端中的聊天历史、全局搜索、闪照隐私与屏幕捕获安全问题」，
  范围 `apps/mobile_flutter`；只做代码 + 测试 + 本地验证，**不拉 PR、不真机测试（用户执行）**，
  禁止向业务 API 发送明文/密钥/解密媒体，不削弱 E2EE/RBAC/审计。
- 关联计划/ADR：无新 ADR（不改 E2EE/账本/鉴权边界）；本任务记录 + `docs/verification/2026-09-17-chat-history-search-flash-screen-security.md`。
- 当前状态：**待真机验收**（本地实现与验证完成；2026-09-17 05:46:47 +08 已构建 0.3.92-debug/2126
  并保留数据覆盖安装 Mi 6；未做正式发布、未部署）。
- 负责人、工作树、文件所有权、源码 commit：主工作树 `D:\pythonProject\outsource\StarChat`，
  分支 `main`，基线 commit `08f1fc3d`，本任务提交 `6d1dcdac`（未 push）。文件所有权：`apps/mobile_flutter/lib/features/matrix/*`、
  `lib/features/search/*`、`lib/ui/chat/*`、`android/.../MainActivity.kt`、`ios/Runner/AppDelegate.swift` 及对应测试。
- 最后更新时间（含时区）：2026-09-17 05:50（Asia/Shanghai）。
- 下一条具体操作、必要输入、阻断的验收 ID：用户按 2126 交付记录第 4 节真机验收
  （A 日期、B 搜索、C/D 闪照、E 屏幕捕获）；若发现问题，附截图/录屏与操作步骤。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 日历日期状态与聊天正文解耦（打开日历不依赖已加载记录） | `RoomHistoryDayIndex` + `loadMonthDays` + `RoomPage` 不再用 `loadedDayMetadata` | `room_history_day_index_test`(15)、`history_delivery_regression_test`（源码契约：无 `loadedDayMetadata`、无 `DateTime(1970`） | 未构建 | 待真机确认翻月手感 |
| A2 | unknown 不显示成“无消息”，未来日期禁用 | `RoomHistoryDayState` 六态 + 月历渲染分支 | `calendar_unknown_past_dates_test`(8) | 未构建 | — |
| A3 | 最早月份未知时不得伪造 1970 | `earliestMonth` 索引→创建时间→null；`earliest` 可为 null | `matrix_room_history_date_capability_test`（`earliestMonth is null`） | 未构建 | — |
| A4 | 月查询有界、可取消、过期响应丢弃 | `loadMonthDays`（≤2 次探测/5s）、`cancelMonthLookup`、UI generation | 能力测试（2 次探测、缓存命中 0 探测、取消后仍 unknown）、月历测试（切月取消 + 过期响应丢弃） | 未构建 | — |
| A5 | 已知 anchor 的日期跳过重复 `timestamp_to_event` | `anchors[day]` → `anchorForDay()` → `onDateLookup` 快路径 | 能力测试（anchor 本地读取、探测次数不变） | 未构建 | — |
| B1 | 全局搜索结果为 typed（联系人/群聊/聊天记录分区） | `GlobalSearchResults/ContactResult/RoomResult/MessageHit/ConversationHit` | `global_search_controller_test`(10)、`global_search_page_test`(12) | 未构建 | — |
| B2 | 空查询是分区空态而不是空白结果 | `GlobalSearchController.isBlank` + 立即空态 | 页面测试（空查询不请求、不发业务 API） | 未构建 | — |
| B3 | 设备侧真实聊天记录检索 + room+event 锚点导航 | `GlobalSearchIndex`（内存/会话）+ `RoomOpenRequest.anchorEventId` → `RoomPage.initialAnchorEventId` | `room_page_anchor_navigation_test`(3)、`global_search_page_test`（单条锚点/多条会话页） | 未构建 | 待真机确认跳转落点 |
| B4 | debounce 200–300ms + generation 抑制过期结果 | `GlobalSearchController(debounce: 250ms)` + generation | 控制器测试（debounce、过期抑制） | 未构建 | — |
| B5 | 不向业务 API 发送查询/明文 | 搜索只读本地索引；页面仅注入 contacts/rooms loader | 控制器/页面测试断言无业务调用 | 未构建 | — |
| C1 | 闪照不再丢 `isFlashPhoto`，搜索媒体不含闪照 | 搜索投影携带标志 + `MediaMessageAccessPolicy` | `media_message_access_policy_test`(10) | 未构建 | — |
| C2 | 闪照不进普通 Gallery，预取不触碰闪照 loader | `ordinaryGalleryMessages()` 数据集排除 + `assertOrdinaryMediaAllowed` | `room_media_gallery_projection_test`、`room_page_flash_integration_test`（Gallery 数据集只有普通图片） | 未构建 | — |
| D1 | 闪照查看 3 秒（代码/文案/测试） | `viewDuration = 3s` + 提示文案 | `flash_photo_test`（3 秒契约） | 未构建 | 手感待真机 |
| E1 | Android `FLAG_SECURE` + 租约计数 | `MainActivity.kt` `secureLeaseCount` | `screen_capture_protection_test`（源码契约 + Dart 租约） | 未构建 | **待真机验证截图/录屏/最近任务** |
| E2 | 捕获开始/截图/后台 → 销毁；捕获中禁止 reveal | `flash_photo.dart` + `ScreenCaptureProtection` | `flash_photo_test`（阻断、截图后销毁、生命周期销毁、水印） | 未构建 | iOS 真机时序待验证 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源 commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android（Mi 6 真机测试包） | **0.3.92-debug / 2126**，已保留数据覆盖安装（此前 2125） | `6d1dcdac` | `com.liuhetong.mobile`，固定证书 `75b31c66…ba61fff` | `artifacts/2026-09-17/android-0.3.92-debug-2126/ChatFlow-0.3.92-debug-2126-arm64-rebuilt.apk`，SHA256 `7ca01bb1c035355c0ad94b331d3b6e21f302fa7cf211307997a0d26df4ee4942`（设备回读一致） | 2026-09-17 05:46:47 +08；[2126 交付记录](../../verification/2026-09-17-chat-history-search-flash-2126-mi6.md) |
| iOS | 未构建（无签名/设备条件） | 同上 | — | — | 无 |
| 业务 API | 未改动 | — | — | — | 无 |

测试记录：命令与退出码、通过数见 `docs/verification/2026-09-17-chat-history-search-flash-screen-security.md` 第 5 节；
日志原文 `docs/verification/artifacts/2026-09-17/flutter-full-stage3-final.txt`（全量）与定向套件输出。
工具版本：Flutter 3.44.9 / Dart 3.12.2，Windows；`flutter analyze lib test` 无问题。
未执行：`scripts/verify.ps1`（缺 `.env`，历史长期缺失）、构建、真机、部署。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| A 索引/能力/月历 | 2026-09-17 | 2026-09-17 | 主动实现 + 2 次返工（anchor 取“当天最早”、索引并发加载竞态） | 与 C/D/E 交叉 | 定向套件全绿 | 进入 B |
| B 全局搜索 | 2026-09-17 | 2026-09-17 | 主动实现 | 同上 | 22 项全绿 | 进入 E |
| C/D 媒体与时长 | 2026-09-17 | 2026-09-17 | 主动实现 + 1 次返工（Gallery 顺序断言） | 同上 | 22 项全绿 | — |
| E 屏幕保护 | 2026-09-17 | 2026-09-17 | 主动实现 | 同上 | 9 项全绿 | 真机 |
| 回归 | 2026-09-17 | 2026-09-17 | 全量测试等待（工具） | — | 见验证记录 | 提交 |

总墙钟：单会话内完成（用户提供的任务在同一天内交付）；重复工作：月索引 anchor 语义与「并发加载双实例」两次返工，
避免措施：`_dayIndexLoad` 单例 Future、`_DayEntry.firstSeenAt` 以真实事件时间戳比较。

## 交接与回退

- 已确认根因/已排除假设：见验证记录第 1 节（A1–E4）。已排除：日历问题不是 SDK `getEventByTimestamp` 本身失效，
  而是客户端把“本地是否已加载”当成“当天是否有消息”；闪照泄漏不是 UI 隐藏不足，而是数据集与能力判据缺失。
- 待办及验收失败项：真机（Android 截图/录屏/最近任务、iOS 录屏与截图时序、翻月与日期跳转手感）。
- 已发布与仅候选的区别：**无正式发布**。Android debug 真机测试包 0.3.92-debug/2126 已安装 Mi 6
  （用户要求的测试包）；生产 API/DB 与正式更新通道未改动。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（无生产变更）。代码回退 = 撤销 `6d1dcdac`；
  设备回退 = 重新安装 2125 交付包（`android-0.3.92-debug-2125/…-rebuilt.apk`，同签名可覆盖）。
- 运行中 CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：`git status` 中本任务改动是否已提交；全量测试数（`flutter-full-stage3-final.txt` 末行）；
  用户真机反馈（尤其 iOS 录屏阻断与 Android 最近任务预览）。
