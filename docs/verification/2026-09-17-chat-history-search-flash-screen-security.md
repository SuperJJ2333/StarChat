# 聊天历史日期查询、全局搜索、闪照隐私与屏幕捕获安全（2026-09-17，本地完成，未构建/未真机）

范围：`apps/mobile_flutter`（ChatFlow Flutter 客户端）。任务 A–E 五项。**未构建 APK/IPA、未安装真机、未部署**；
真机验收由用户执行。服务端未改动，未向业务 API 发送任何明文。

## 1. 根因

### A 聊天历史日期查询（日期 metadata 与时间线正文耦合）

| # | 根因 | 位置（修复前） |
| --- | --- | --- |
| A1 | 月历“哪些天有消息”来自**已加载时间线正文的投影**（`controller.loadedDayMetadata`），日期可用性取决于聊天记录是否已加载 | `room_page.dart` `datesWithMessages` → `ChatSearchPage.datesWithMessages` |
| A2 | 缺覆盖证据时把日期一律当“无消息”灰显禁用，只有 `allowUnknownPastDates: true` 这条产品旁路才敢让用户点 | `chat_search_page.dart` `dayStatus()` / `allowUnknownPastDates` |
| A3 | 最早月份用 `roomLease.creationDate ?? DateTime(1970)` 兜底，创建时间未知时日历可以翻到 1970-01 | `room_page.dart` `earliestMonth` |
| A4 | 月在打开/切月时**不查询**（避免历史扫描），导致“本月暂无聊天记录”与“尚未加载”无法区分 | `if (!widget.allowUnknownPastDates) unawaited(_loadMonth())` |
| A5 | 选日期后定位仍可能整月串行回溯（`locateDay` 13s 预算 + context 分页） | 未变（保留为兜底），新增月索引 anchor 快路径 |

### B 全局搜索（结果类型、空查询与分区）

| # | 根因 | 位置 |
| --- | --- | --- |
| B1 | 结果是无类型 `String` 列表，UI 只能按字符串猜分区/可点行为 | 旧 `GlobalSearchPage` |
| B2 | 空查询路径把“无输入”当成一次检索（或在过滤后立刻返回空），出现空白结果页而非分区空态 | 旧查询状态机 |
| B3 | 只搜“联系人/群名”入口数据，没有真正的设备侧聊天记录检索与 room+event 锚点导航 | 旧实现 |
| B4 | 无 debounce / 无 generation，快速连续输入会串台发布过期结果 | 旧实现 |

### C 闪照媒体泄漏

| # | 根因 | 位置 |
| --- | --- | --- |
| C1 | 搜索投影构造 `ChatSearchMessage` 时丢掉 `isFlashPhoto`，闪照在搜索页变成普通图片资产 | `room_page.dart` 搜索投影 |
| C2 | 普通大图 Gallery 直接由“所有图片消息”构造，未做闪照排除；Gallery 会预取 ±1 邻居，于是闪照原图被普通 loader 加载 | `_galleryImages()` |
| C3 | “闪照不能进普通媒体路径”这条规则散落在多处 `isFlashPhoto` 判断，没有单一能力判据 | 多处 |

### D 闪照查看时长

| # | 根因 | 位置 |
| --- | --- | --- |
| D1 | 产品要求 5 秒 → 3 秒（含代码、UI 文案、测试、注释） | `FlashPhotoViewerPage.viewDuration` 等 |

### E 屏幕捕获安全

| # | 根因 | 位置 |
| --- | --- | --- |
| E1 | Android 侧没有任何 `FLAG_SECURE`，闪照可被系统截图/录屏/最近任务预览抓取 | `MainActivity.kt` |
| E2 | 无引用计数：一旦按“打开/关闭”开关，多查看器（或多个入口）会互相误关 | 新增原生计数 |
| E3 | iOS 侧没有捕获状态上报：录屏/镜像进行中仍可 reveal 闪照，系统截图后也不销毁 | `AppDelegate.swift` |
| E4 | 查看器不感知生命周期：退到后台仍在展示原图 | `flash_photo.dart` |

## 2. 修改文件

新增（lib）

- `lib/features/matrix/room_history_day_index.dart`：`CalendarMonth`、`RoomHistoryDayState`、`RoomHistoryMonthDays`、`RoomHistoryDayIndex`（**metadata only**：日期/边界/anchor/覆盖/schema 版本，无正文字段）。
- `lib/features/matrix/room_history_day_index_store.dart`：account scoped SharedPreferences 持久化（损坏/版本不匹配退化为空索引；账号隔离）。
- `lib/features/matrix/media_message_access_policy.dart`：闪照/普通媒体**唯一能力判据**。
- `lib/features/matrix/room_media_gallery_projection.dart`：`ordinaryGalleryMessages()`（普通 Gallery 数据集，排除闪照/撤回/未发送）。
- `lib/features/matrix/screen_capture_protection.dart`：`ScreenCaptureProtection` + `ScreenCaptureLease`（租约幂等、平台异常静默降级、捕获状态与截图流）。
- `lib/features/search/global_search_models.dart`、`global_search_index.dart`、`global_search_controller.dart`：typed 结果、设备侧内存索引、debounce + generation。

重写

- `lib/ui/chat/chat_search_page.dart`（`CalendarPickerPage` typed 月历：knownPresent/knownEmpty/unknown/未来/加载/失败六态；切月与关闭取消在途查询；去掉 `allowUnknownPastDates`）。
- `lib/features/search/global_search_page.dart`（联系人/群聊/聊天记录三分区 + ≤3 条 + 更多入口 + 会话聚合 + 锚点跳转）。

修改

- `lib/features/matrix/matrix_e2ee_client.dart`：日期索引接入 `_SdkRoomTimelineCapability`（`earliestMonth` / `loadMonthDays` / `cancelMonthLookup` / `anchorForDay`、索引预热、幂等加载 Future）、月查询有界探测（≤2 次 `timestamp_to_event`，5s 超时，本地时区换算）。
- `lib/features/matrix/room_history_date_capability.dart`、`matrix_room_timeline_adapter.dart`、`room_timeline_controller.dart`：能力/适配器/控制器透传（含 `anchorForDay`）。
- `lib/features/matrix/room_page.dart`：日期 metadata 改由索引提供（**删除 1970 兜底**）、`loadCalendarMonth`、anchor 快路径、闪照策略化（搜索投影/Gallery/查看器/预览/原图/转发）、`initialAnchorEventId` 定位高亮、设备侧索引记录。
- `lib/features/matrix/chat_media_shared_logic.dart`：删除重复 `CalendarMonth` 与旧 `dayStatus`（改为 re-export typed 模型）。
- `lib/features/matrix/matrix_home_page.dart`、`room_navigation_coordinator.dart`、`lib/app_home.dart`：`anchorEventId` 正式请求参数贯通。
- `lib/ui/chat/flash_photo.dart`：3 秒、捕获阻断、截图后销毁、生命周期销毁、动态水印、销毁态文案。
- `android/app/src/main/kotlin/com/liuhetong/mobile/MainActivity.kt`：`FLAG_SECURE` + `secureLeaseCount` 引用计数 + `chatflow/screen_security` / `chatflow/screen_capture` 通道。
- `ios/Runner/AppDelegate.swift`：捕获状态上报（`UIScreen.isCaptured` / `sceneCaptureState`）+ 截图后通知；无相册访问、无私有 API。

测试（新增/更新）

- 新增：`test/features/matrix/room_history_day_index_test.dart`、`media_message_access_policy_test.dart`、`room_media_gallery_projection_test.dart`、`screen_capture_protection_test.dart`、`room_page_anchor_navigation_test.dart`、`test/features/search/global_search_controller_test.dart`、`global_search_page_test.dart`。
- 更新（旧契约编码了旧架构）：`calendar_unknown_past_dates_test.dart`、`calendar_history_loading_test.dart`、`chat_search_page_test.dart`、`chat_search_feedback_test.dart`、`chat_media_shared_logic_test.dart`、`history_delivery_regression_test.dart`、`matrix_room_history_date_capability_test.dart`、`room_timeline_controller_test.dart`、`direct_chat_service_test.dart`、`room_page_flash_integration_test.dart`、`flash_photo_test.dart`。

## 3. 架构变化

1. **日期 metadata 与聊天正文彻底解耦**：日历只需要 `RoomHistoryMonthDays`（日期 → knownPresent/knownEmpty/unknown + anchor + 覆盖）。判定“空”必须有证据：早于房间创建时间、落在本机连续覆盖区间内、或一次 targeted 探测结论；“本地没有这天”永远是 `unknown`，且 `unknown` 在 UI 上保持可点。
2. **月查询有界**：一次 `loadMonthDays` 最多 2 次 `timestamp_to_event`（月起点向后 + 月终点向前，各 5s 超时），**不加载正文/媒体**，不切换历史 context；本地索引命中即直接返回（缓存月份 0 次网络）。
3. **anchor 契约**：`RoomHistoryMonthDays.anchors[day]` → `RoomHistoryDateCapability.anchorForDay()` → `RoomPage.onDateLookup` 快路径；全局搜索的 room+event 锚点走 `RoomOpenRequest.anchorEventId → RoomPage.initialAnchorEventId`（无全局变量、无 SharedPreferences）。
4. **单一媒体能力判据**：`MediaMessageAccessPolicy.forMessage(isFlashPhoto:)`；闪照拒绝搜索媒体、普通 Gallery、普通原图 loader、普通查看器、转发/保存/收藏/编辑；只有 `FlashPhotoViewerPage` 能加载原图。普通 Gallery 的“邻居预取不可能碰到闪照”由**数据集排除**保证（而不是靠 UI 隐藏）。
5. **屏幕保护租约化**：Dart 侧 token 集合 + 原生 `secureLeaseCount` 双计数；第一个租约开启、归零才清除、重申只重新应用、释放幂等。iOS 明确不声称阻止截图，只有捕获状态上报与“截图后销毁”补救。

## 4. 闪照最终行为

| 场景 | 行为 |
| --- | --- |
| 气泡 | 马赛克 + 闪电角标；已看过显示「闪照已销毁」且点击不再打开 |
| 查看时长 | 长按查看 **3 秒**（`FlashPhotoViewerPage.viewDuration = 3s`，提示文案同步） |
| 打开瞬间正在录屏/共享屏幕 | **不 reveal**，显示「正在录屏或共享屏幕，无法查看闪照」；此时长按不消耗查看次数 |
| 查看中开始录屏/投屏 | 立即隐藏原图并销毁（原图引用置空、回调 `onDestroyed` 标记已看），不可恢复 |
| 系统截图（iOS，截图**之后**才收到通知） | 立即按销毁处理 |
| 应用退到后台/失活 | 立即销毁，回前台不自动恢复，并重申安全窗口（Android Activity 重建兜底） |
| 查看中 | 动态水印「闪照 · 仅限当前查看」 |
| 转发/保存/收藏/编辑 | 全部拒绝（气泡菜单无转发入口；`MediaMessageAccessPolicy` 拒绝） |
| 普通 Gallery | 数据集中不存在闪照；邻居预取因此不可能调用闪照 loader |
| 「图片与视频」历史搜索 | 闪照不参与媒体筛选 |
| 已看状态 | account scoped 持久化（上限淘汰最旧），跨设备不同步 |

## 5. 测试与验证

环境：Flutter 3.44.9 / Dart 3.12.2，Windows，`C:\src\flutter\bin\flutter.bat`。

```
flutter analyze lib test        → No issues found!
flutter test --timeout 60s <定向套件>  → 全部通过
flutter test --timeout 120s     → 见下（全量）
```

定向证据（真实输出，非推断）

| 套件 | 结果 |
| --- | --- |
| `room_history_day_index_test.dart` | 15 passed |
| `matrix_room_history_date_capability_test.dart` | 15 passed（含 Task A 月 metadata 5 项） |
| `calendar_unknown_past_dates_test.dart` + `calendar_history_loading_test.dart` | 14 passed |
| `screen_capture_protection_test.dart` | 9 passed |
| `room_media_gallery_projection_test.dart` + `room_page_flash_integration_test.dart` + `media_message_access_policy_test.dart` | 22 passed |
| `room_page_anchor_navigation_test.dart` | 3 passed |
| `direct_chat_service_test.dart` | 9 passed |
| `test/ui test/features/matrix test/features/search`（回归） | 1864 passed / 1 failed（`direct_chat_service_test` 旧签名契约，已更新契约后单测 9 passed） |
| 全量 `flutter test` | 见 `artifacts/2026-09-17/flutter-full-stage3-final.txt` |

关键断言（防止回归的硬约束）

- `history_delivery_regression_test.dart`：`room_page.dart` **不含** `DateTime(1970`、不含 `loadedDayMetadata`，且必须含 `loadCalendarMonth:` / `load.loadMonthDays(month)`。
- `room_media_gallery_projection_test.dart`：源码契约断言 `ordinaryGalleryMessages(`、四个 `assertOrdinaryMediaAllowed('...')`、`canUseOrdinaryViewer` + 「闪照仅可在闪照查看器中打开」、搜索网格 `StateError`。
- `screen_capture_protection_test.dart`：`MainActivity.kt` 必须含 `FLAG_SECURE`/`addFlags`/`clearFlags`/`secureLeaseCount`/`reassertSecure`，且**不含** `MediaStore`/`READ_MEDIA_IMAGES`；`AppDelegate.swift` 必须含 `isCaptured`/`sceneCaptureState`/`userDidTakeScreenshotNotification`，且不含 `PHPhotoLibrary`/`UIImageWriteToSavedPhotosAlbum`。
- `room_history_day_index_test.dart`：JSON 中不含 `body`/`plaintext`/`mxc://`/`accessToken`；版本不匹配整体丢弃；`earliestKnownDay` 不把创建时间/覆盖区间当成“有消息”。

## 6. 剩余风险与明确不能声称的能力

1. **无法阻止用另一台物理设备拍摄屏幕**（相机拍屏、外接采集卡）。Android `FLAG_SECURE` 与 iOS 捕获状态都改变不了这一点。
2. **iOS 没有官方等价的截图阻止 API**：`userDidTakeScreenshot` 在截图**完成之后**触发，因此 iOS 只能“事后立即销毁”，不能声称阻止截图或阻止录屏。iOS 的录屏阻断仅体现为“检测到捕获开始时禁止 reveal / 立即销毁”。
3. Android 侧依赖系统实现：部分定制 ROM 的录屏/投屏、无障碍截屏工具或 root 设备可能绕过 `FLAG_SECURE`；未做 root/越狱对抗，也未做二次相机对抗。
4. 销毁只释放 `Uint8List` 引用（`_bytes = null`），**不声称内存零化**：GC 之前的内存内容、系统合成器/GPU 纹理不在可控范围。
5. 日期索引是**本机 metadata**：换设备/重装后覆盖证据重建，未知日期会先显示为 `unknown`（可点、会查询），不会误报为空。索引落盘只含日期/anchor/覆盖，不含正文。
6. 设备侧全局搜索索引是会话内存索引（进程退出即消失，账号切换清空）；它不是服务端索引，也不参与 E2EE 密钥。
7. 真机未验证项：Android 真机截图/录屏/最近任务是否确被阻断、iOS 真机录屏与截图通知时序、各厂商 ROM 差异。本次未构建包、未安装、未部署。

## 7. 复用依据与未执行项

- 复用了既有 `RoomHistoryLookupIncomplete/Cancelled` 语义与 `_scrollToMessage`/`openAnchor` 定位链路；未改 Matrix E2EE、RoomLease 生命周期、媒体缓存、分页、身份缓存。
- 未执行：`scripts/verify.ps1`（需 `.env`，历史记录中长期缺失）、Android/iOS 构建、真机安装、生产部署、服务端变更。
