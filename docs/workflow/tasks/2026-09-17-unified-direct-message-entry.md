# 任务记录：好友资料「发消息」统一入口（通讯录与朋友圈/群聊收敛到 AppHome）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 报「多个好友资料入口的上层实现不统一」：
  朋友圈/群聊走 `AppHome._openMessage`，通讯录走自己重复实现
  （`_ContactsTabPageState._openMessage`：直接 `contact.matrixUserId` + 自建 `openRoomLease`
  + 自建 `RoomPage` + 自建 `setOnRevoked`）。要求所有「好友资料 → 发消息」入口统一为
  `ContactProfilePage → 统一 ContactAction.onMessage → AppHome 统一入口 → 权威 ContactDetails
  → DirectChatController → CoordinatedDirectChatGateway → canonical 加密私聊 → _openManagedRoom
  → RoomPage`。
  边界（用户明确）：不 pull 代码、不真机测试、不改无关功能、不为重构大面积改动
  Matrix/群聊/朋友圈架构；必须保留 DirectChatController、CoordinatedDirectChatGateway、
  权威 ContactDetails 机制、RoomLease 生命周期与好友身份缓存机制。
- 关联计划/ADR：无独立计划或 ADR（入口收敛 + 身份解析审计，未触碰受保护变更）。
  验证记录 [2026-09-17-unified-direct-message-entry](../../verification/2026-09-17-unified-direct-message-entry.md)；
  2125 交付记录 [2026-09-17-unified-entry-2125-mi6](../../verification/2026-09-17-unified-entry-2125-mi6.md)。
- 当前状态：实现与本地验证完成；已构建 **0.3.92-debug/2125** 并保留数据覆盖安装 Mi 6；**待用户真机验收**
- 负责人、工作树、文件所有权、源码commit：主工作树 `D:\pythonProject\outsource\StarChat`
  （分支 main，基线 `21cb52b5`）。拥有：
  `apps/mobile_flutter/lib/app_home.dart`、
  `apps/mobile_flutter/lib/features/matrix/direct_chat_entry.dart`（新增）及对应测试。
- 最后更新时间（含时区）：2026-09-17 02:0x +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收ID：由用户在自己环境构建/真机验收 A1–A4；
  无阻断项。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 通讯录 → 好友 → 好友资料 → 发消息：与朋友圈/群聊走同一条统一入口，不再自建房间/租约/路由 | 删除 `_ContactsTabPageState._openMessage`；`ContactsTabPage` 新增 `required ContactAction onMessage`，AppHome 传 `_openMessage`；`ContactsPage`/`ContactProfilePage` 原样透传 | 源码接线测试（ContactsTabPage 段不得含 `openRoomLease`/`RoomPage(`/`setOnRevoked`/`directChats.open`）；`direct_message_identity_test`（同一函数对象透传 + 资料页动作调用它）；`contact_flow_test` 既有用例 | 未构建 | 待用户 |
| A2 | 权威身份：按业务 userId 解析，Matrix ID 已更新的旧快照仍能打开正确会话 | `resolveFriendContact()`：userId 主键 → 目录命中即用；缺失 preload + 静默刷新一次；仍无（userId 与 Matrix ID 都不在目录）才判「已不是好友」 | `direct_chat_entry_test`：新好友刷新后打开、缓存命中不额外请求、旧 Matrix ID 用当前映射、userId 形态不同用目录条目、缺绑定用入口快照补齐且保留备注、非好友抛可分类错误 | 未构建 | 待用户 |
| A3 | 不出现重复 canonical 房间 / 重复 RoomPage | `DirectChatController._openings` 未改动；新增 `DirectMessageOpenGate` 单飞闸门（同一好友在途/已打开时忽略重复点击），失败先释放闸门再弹窗以便「重试」可重新进入 | `direct_chat_entry_test`（闸门去重/释放/不同好友独立/空键不参与）；`direct_chat_controller_test` 既有并发用例；接线测试断言闸门在位 | 未构建 | 待用户 |
| A4 | 群聊/朋友圈/会话资料入口行为不变 | 群聊：好友成员仍走 `onOpenFriendContact → _openContact → ContactProfilePage(onMessage: widget.onMessage)`，非好友仍进 `AddFriendProfilePage`，自己仍不可点；朋友圈：好友仍进 `ContactProfilePage(contactActions.onMessage)`，非好友仍进 `AddFriendProfilePage`，SELF 不变 | 既有 `group_member_profile_test`、`moment_profile_privacy_test`、全量回归 | 未构建 | 待用户 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android Debug（仅 Mi 6 真机） | 0.3.92-debug / 2125 | `e0fa42c0`（含 2124 的三项聊天修复） | `com.liuhetong.mobile`，固定身份 `75b31c66…ba61fff` | `artifacts/2026-09-17/android-0.3.92-debug-2125/ChatFlow-0.3.92-debug-2125-arm64-rebuilt.apk`，SHA256 `9fb1302d…6452c8e`（源码中间包 `5cb79c84…afcc11`） | 2026-09-17 02:11:13 +08 覆盖安装成功，firstInstallTime 未变；**未做正式发布** |
| iOS | 未构建 | — | — | — | 未发布 |
| 服务端 | 未改动（2124 的红包总额 API 已于 2026-09-17 00:34 +08 部署） | — | — | — | — |

测试记录：

- `flutter analyze`（全量）→ 退出码 0，`No issues found!`。
- 定向：`test/features/matrix/direct_chat_entry_test.dart`（新增 9）、
  `profile_message_route_wiring_test.dart`（3）、`contacts/direct_message_identity_test.dart`（1）
  → 13 通过 / 0 失败。
- 受影响面：`features/contacts` + `features/matrix/{direct_chat_entry,direct_chat_controller,
  profile_message_route_wiring,group_member_profile}` + `app_home_lifecycle_test`
  → **127 通过 / 0 失败**。
- `flutter test`（全量）→ 退出码 0，**2721 通过 / 0 失败**（本任务前 2712）。
  日志 `artifacts/2026-09-17/flutter-full-direct-message-entry.txt`。
- 变异探针（改动后复原，证明新用例能抓住旧行为）：
  ① `resolveFriendContact` 去掉 userId 主键分支 → 2 个身份用例失败；
  ② 通讯录不再透传统一入口（`onMessage: null`）→ 接线/透传用例失败；
  ③ 去掉单飞闸门 → 接线测试失败。
- 2125 重建验证：清单语义一致、原生/Flutter 资产差异 0、smali 类差异 0（27313/27313）、
  ZIP 条目 948/951；`zipalign -c -P 16 4`、`aapt`（2125 / 0.3.92-debug / debuggable / arm64-v8a）、
  `apksigner verify`（固定证书）通过。日志 `artifacts/2026-09-17/{build-2125.log,verify-2125.log,install-2125.log}`。
  门禁复用依据：本轮源码 `e0fa42c0` 已跑过 analyze 与全量测试，构建脚本冻结的
  `source-input-sha256-before/after.json` 一致，故未重复整套门禁。
- 未执行项：未构建 iOS；未做正式发布；未部署服务端（用户要求本次不做）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 代码通读（入口/身份/租约/并发） | 2026-09-17 01:1x +08 | 01:3x | 主动 | — | 源码追踪 | — |
| 统一入口实现 + 新文件 | 01:3x | 01:5x | 主动 | — | `flutter analyze` | — |
| 测试（新增/改写） | 01:5x | 02:0x | 主动 | 与全量门禁并行 | 见上 | — |
| 变异探针与复原 | 02:0x | 02:1x | 主动 | — | 3/3 按预期转红 | — |
| 文档与索引 | 02:1x | 进行中 | 主动 | — | — | — |

总墙钟：约 60 分钟（未逐段精确计时，不估成精确值）。

## 交接与回退

- 已确认根因：通讯录 `_ContactsTabPageState._openMessage` 是 AppHome `_openMessage`/
  `_openManagedRoom` 的第二份实现，且**只按入口快照的 `matrixUserId`** 判定好友身份
  （AppHome 至少还按 `userId` 取权威条目）；其 RoomLease/`setOnRevoked` 实现也与
  `_openManagedRoom` 略有差异（多一次 `removeRoute` + `await route.popped`）。
- 已排除假设：canonical 房间本身一直是统一的（`DirectChatController` +
  `CoordinatedDirectChatGateway` 未被绕过）；群聊/朋友圈入口没有自建私聊房间。
- 行为变更（需知悉，均已在验证记录中说明）：
  1. `_openMessage` 改为「userId 主键」解析：Matrix ID 已更新的旧快照从此可正常打开
     （旧实现会按旧 Matrix ID 判为「已不是好友」而报错）；非好友仍然失败且文案不变。
  2. 入口快照回填目录改为「只补 Matrix 绑定、保留目录本机字段（备注/标签/朋友圈权限/
     在线状态）」，不再用入口快照整体覆盖目录条目。
  3. 新增单飞闸门：同一好友在途/已打开期间的重复「发消息」被忽略（以前会叠加第二个
     RoomPage）；失败时先释放闸门，弹窗「重试」仍可重新进入。
  4. `ContactsTabPage.reminderService` 参数删除（它只为已被删除的重复 RoomPage 而存在），
     AppHome 调用点同步去掉。
  5. `_refreshMissingFriendIdentity` 原样搬到 `direct_chat_entry.dart` 并改名
     `ensureCurrentFriendIdentity`（矩阵索引契约不变，仍服务于通话/通知/接受好友三条路径）。
- 待办及验收失败项：A1–A4 待用户真机验收（2125 已安装 Mi 6）。
- 已发布与仅候选的区别：Android 2125 为**真机 debug 测试包**，未做正式发布；服务端本任务未改动
  （2124 的红包总额可见性 API 已于 2026-09-17 00:34 +08 部署）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：`ContactsTabPage` 是否仍只透传 `widget.onMessage`；
  `direct_chat_entry.dart` 是否仍是「发消息」唯一身份解析；
  `DirectChatController._openings` / `CoordinatedDirectChatGateway` 是否未被动过。

## 后续修复（2026-09-17，本任务的行为已被修正）

本任务 A3 引入的 `DirectMessageOpenGate` 把「好友是否正在打开」一直持有到 RoomPage 关闭
（`await Navigator.push` 只在页面关闭后完成），导致 Room A 打开期间再次「好友资料 → 发消息」
被闸门静默吞掉、无任何反应。该边界已修正：闸门只锁「身份解析 + canonical roomId」，
页面打开交给 `RoomNavigationCoordinator`，并发语义改为 single-flight。
见[任务记录](2026-09-17-direct-message-gate-lifecycle.md)与
[根因/验证](../verification/2026-09-17-direct-message-gate-lifecycle.md)。
本任务 A1/A2/A4 的行为与结论不受影响。
