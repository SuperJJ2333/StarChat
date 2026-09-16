# 任务记录：第二阶段——房间导航统一（RoomNavigationCoordinator）与通话身份修复

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 要求处理第一阶段遗留的两个问题：
  ① 消息列表直接打开 RoomPage 仍是绕过 AppHome 统一房间导航的第二套路由生命周期；
  ② `_openCall` 仍使用入口快照里可能过期的 `contact.matrixUserId`。
  要求：同一 roomId 只允许一个活动 RoomPage；已打开时 `popUntil` 回到原页面；并发同 roomId
  只取一次租约/只 push 一次；保留 RoomLease 全部生命周期语义；`_openCall` 改用
  `resolveFriendContact`；audio/video 均用权威 matrixUserId；CallPage 展示权威联系人；
  `DirectChatController` / `CoordinatedDirectChatGateway` / E2EE 不改。
  禁止范围（用户列明）：Matrix 房间创建协议、canonical 逻辑、E2EE/Olm/Megolm、登录/L04/L07、
  个推/FCM/APNs、通话媒体/WebRTC/TURN/ICE、群聊业务规则、朋友圈逻辑、好友 schema、
  Matrix SDK adapter 结构、UI 样式。不需要 pull/真机/打包/部署。
- 关联计划/ADR：无独立计划或 ADR（导航所有权收敛 + 身份解析一致性，未触碰受保护变更）。
  验证记录 [2026-09-17-room-navigation-call-identity](../../verification/2026-09-17-room-navigation-call-identity.md)；
  前一阶段 [2026-09-17-unified-direct-message-entry](../../verification/2026-09-17-unified-direct-message-entry.md)。
- 当前状态：实现与本地验证完成；**未构建、未安装、未部署**（用户明确本次不需要）
- 负责人、工作树、文件所有权、源码commit：主工作树 `D:\pythonProject\outsource\StarChat`
  （分支 main，基线 `e0fa42c0`，本阶段改动未提交）。拥有：
  `lib/features/matrix/room_navigation_coordinator.dart`（新增）、
  `lib/features/matrix/direct_chat_entry.dart`（新增 `resolveCallTarget`）、
  `lib/app_home.dart`、`lib/features/matrix/matrix_home_page.dart` 及对应测试。
- 最后更新时间（含时区）：2026-09-17 03:1x +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收ID：A1–A6 待用户在自己环境构建后真机验收；
  无阻断项（本阶段按用户要求不做真机验证）。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 消息列表打开房间只有一套路由生命周期（不再自建租约/RoomPage） | `MatrixHomePage._openRoom` 改为 `onOpenRoom(RoomOpenRequest)` 委托；展示/已读/预热留在列表侧 | `matrix_home_room_delegation_test`（3 项）；`profile_message_route_wiring_test`（源码合同：列表无 RoomPage/openRoomLease/setOnRevoked） | 未构建 | 待用户 |
| A2 | 同一 roomId 不会同时存在两个活动 RoomPage；再次请求回到原页面 | `RoomNavigationCoordinator._active` + `popUntil(identical(route))` | 协调器 Test 2 / Test 5；delegation 测试 | 未构建 | 待用户 |
| A3 | 同一 roomId 并发打开只产生一次 lease/push | `_opening` future 复用（先占位再启动流程） | 协调器 Test 3；Test 7（异常清理）；Test 10（取消期间重开） | 未构建 | 待用户 |
| A4 | RoomLease 生命周期完整：未 mounted 取消、push 异常释放、revoke 只关自身、退出后清 registry | `_openManagedRoomRoute` + `RoomRouteHandle.register/release` | 协调器 Test 1/6/7/9/10 + `onRoomReady/onRoomClosed` 顺序测试 | 未构建 | 待用户 |
| A5 | lease cancel 不阻塞打开下一个房间（也不吞点击） | roomId 级去重；取消只挂住同一 roomId | 协调器 Test 9；Test 10 | 未构建 | 待用户 |
| A6 | `_openCall` 用权威身份：audio/video 都用 authoritative matrixUserId，CallPage 展示权威联系人 | `resolveCallTarget`（复用 `resolveFriendContact`）+ CallPage 参数改权威字段 | `call_entry_identity_test` Test A/B/C；`direct_chat_entry_test`（解析契约） | 未构建 | 待用户 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android / iOS | **未构建**（用户要求本次不做） | 工作树改动（基线 `e0fa42c0`） | — | — | — |
| 服务端 | 未改动 | — | — | — | — |

测试记录：

- `flutter analyze`（全量）→ 退出码 0，`No issues found!`。
- 定向：协调器 11 + 消息列表委托 3 + 通话身份 3 + 接线 5 + direct_chat_service 9 +
  `features/contacts` → 136 通过 / 0 失败。
- 受影响面（`features/matrix`+`features/contacts`+`app_home_lifecycle`+finance/redpacket/transfer）
  → 全绿；日志 `artifacts/2026-09-17/stage2-affected-tests.txt`。
- `flutter test`（全量）→ 退出码 0，**2740 通过 / 0 失败**（阶段一 2721，本阶段新增 19）。
  日志 `artifacts/2026-09-17/flutter-full-stage2-room-navigation.txt`。
- 协调器专项日志 `artifacts/2026-09-17/room-navigation-coordinator-test.txt`。
- 变异探针：先判 `_opening` 再判 `_active` / 去掉 `register` 清 opening / 先启动流程再占位 /
  `_openCall` 改回 `contact.matrixUserId` —— 均按预期转红（改动后复原）。
- 工具：Flutter 3.44.9 / Dart 3.12.2；OS Windows 10 Pro 19045。
- 未执行项：未构建 APK/IPA、未安装真机、未部署（用户要求）；真实租约 revoke 时序与真机取消时长
  未在设备验证。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 入口审计与代码通读 | 2026-09-17 02:2x +08 | 02:5x | 主动 | — | 审计表（验证记录第 2 节） | — |
| 协调器实现 + AppHome/列表改造 | 02:5x | 03:0x | 主动 | — | analyze 无问题 | — |
| 协调器测试（含 3 次返工） | 03:0x | 03:2x | 主动+返工 | — | 测试暴露 3 个状态机缺陷并修正 | — |
| 通话身份修复 + 测试 | 03:2x | 03:3x | 主动 | — | call_entry_identity_test | — |
| 源码合同测试改写 + 格式化 | 03:3x | 03:4x | 主动 | 与全量门禁并行 | format/analyze | — |
| 全量门禁 + 文档 | 03:4x | 进行中 | 工具+主动 | — | 2740 通过 / 0 失败 | — |

总墙钟：约 1 小时 20 分（含 3 次协调器状态机返工，未逐段精确计时）。

## 交接与回退

- 已确认根因：见验证记录第 1 节（两套路由 + 全局 bool 守卫；通话入口直接用入口快照 matrixUserId）。
- **测试暴露并修正的 3 个实现缺陷**（返工记录，均在测试中先红后绿）：
  1. 先判 `_opening` 会把「已打开」误判为「正在打开」→ 改为 `_active` 优先；
  2. `register` 未清 `_opening` → 页面退出后租约取消期间重开同一房间变成静默无操作；
  3. 先启动打开流程再写 `_opening` → 流程同步段的 `register` 被随后赋值覆盖，opening 永不清理。
- 行为变更（需知悉）：
  1. 建群后打开新群改为走统一流程（revoke 实现由 `removeRoute`+`await popped` 变为
     `popUntil` 自身 + 当前则 `pop`，语义等价），建议真机回归「建群 → 退出群聊」；
  2. 消息列表的守卫由全局 `bool _openingRoom` 改为 `Set<String> _openingRooms`：跨房间不再互相阻塞；
  3. 通话页展示与呼叫目标改用权威联系人（这是修复本身）。
- 待办及验收失败项：A1–A6 待用户真机验收。
- 已发布与仅候选的区别：本阶段**没有任何构建或发布**，仅源码与测试改动。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：`builder: (_) => RoomPage(` 是否仍只有 1 处（`app_home.dart`）；
  `matrix_home_page.dart` 是否仍无 `openRoomLease(`/`RoomPage(`；`_openCall` 是否仍只调用一次
  `resolveCallTarget`。
