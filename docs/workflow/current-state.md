# 移动交付恢复索引

## 2026-09-17 Android 0.3.93/2127 发布 + 更新弹窗（**已上线**，真机待用户验收）

用户要求「推送 Android 新版本更新弹窗」，确认参数：0.3.93 + 2127、不强制更新、允许本地 commit。
候选源码 commit **`d30bd051`**（未 push）：`pubspec`/`app_config` 升到 `0.3.93+2127`，含
DirectMessageOpenGate 生命周期修复与 2121→2127 的累积修复；冻结候选全量 `flutter test`
**2835 通过 / 0 失败**、`flutter analyze` 无问题。APK 按固定流程（ARM64 release + 三项 HTTPS
dart-define → Apktool 2.12.1 → zipalign 36.0.0 `-P 16 -f 4` → 固定证书 `75b31c66…`）构建，
aapt 身份 2127/0.3.93/arm64，v2+v3 签名，语义核对 25345/25345 类、338 项原生资产零变化、
清单语义一致；SHA256 **`E1C34A03F42BFE83A3F7E3F67E60010D8CB1754D9F708B727F0DB4AE903BD40F`**
（79,408,158 字节）。16MiB 分块上传 + 服务端合并 SHA 门 + `install -m 0644` 不可变版本文件，
`latest-arm64.apk` 原子切换 2127；更新弹窗发布 trace `android-release-0.3.93-2127-20260917`
（5 条审计，min_supported_build 沿用 3，iOS 行未改）。
**期间发现并修复第二个生产缺陷**：线上 `app_update.py` 只对 iOS 打 `platform` 标记，而
0.3.81/2085 起客户端强制校验 `platform`，因此**现网 Android 更新弹窗一直是关死的**；
已按 admin 流程用在线镜像单文件覆盖修复（`starchat-business-api:app-update-platform-20260917`，
digest `16522404…`，演练先锁定导入路径防 ADR-0071 假绿），切换后 61/61 env、3 mounts、
`127.0.0.1:8082` 不变、healthy、日志无 error。公网服务器+工作站双侧 200/206 + MIME 通过，
公网整包下载 SHA 与本地一致，2121 保留为回退路径。进入
[任务记录](tasks/2026-09-17-android-0393-2127-release.md)或
[发布与验证记录](../verification/2026-09-17-android-0393-2127-release.md)。

## 2026-09-17 第二阶段补丁：DirectMessageOpenGate 生命周期边界（本地完成，未构建/未真机/未部署）

真机复现「Room A → 再进入好友资料 → 再点发消息 → 完全没反应」。根因：`_openMessage` 把整个打开流程
（含 `await Navigator.push(RoomPage)`，该 Future 只在页面关闭后完成）都放在 `DirectMessageOpenGate` 内，
于是 Room A 打开期间同一好友的第二次请求在上游被 `claim()` 静默丢弃，根本到不了
`RoomNavigationCoordinator` 的 `popUntil`（两个组件重复管理「页面是否打开」）。修复：新增
`DirectMessageTarget{roomId, authoritativeContact}`，闸门锁定范围缩到「权威身份解析 + canonical
roomId」，`_openManagedRoom` 移到闸门之外；`DirectMessageOpenGate` 由 `claim/release`（已有在途则
no-op）改为 `run(key, operation)` **single-flight**（已有在途返回同一个 Future，成功/失败都释放）。
`RoomNavigationCoordinator`、`DirectChatController`、`CoordinatedDirectChatGateway`、canonical 仲裁、
`MatrixRoomLease`、E2EE 均 0 改动。新增集成回归
`test/features/matrix/direct_message_open_lifecycle_test.dart`（6 例，穿过真实 onMessage → 闸门 →
resolveFriendContact → 控制器/网关 → 协调器 → RoomPage/租约，只替换传输与缓存）；修复前 Test 2/3/6
转红（第二次请求被吞、资料页未被 pop），修复后全绿。变异探针：① `_openManagedRoom` 放回闸门内 →
Test 2/3/6 转红；② 闸门吞掉重复 flight → single-flight 单元用例与并发 Test 4 转红（均已复原）。
`flutter analyze` 无问题；定向 162 通过 / 0 失败；全量 `flutter test` **2835 通过 / 0 失败（退出码 0）**
（本任务前 2826）。**未构建 APK/IPA、未安装真机、未部署**（用户明确本次不需要）。进入
[任务记录](tasks/2026-09-17-direct-message-gate-lifecycle.md)或
[根因/验证/剩余风险](../verification/2026-09-17-direct-message-gate-lifecycle.md)。

## 2026-09-17 第三阶段：聊天历史日期查询、全局搜索、闪照隐私与屏幕捕获安全（本地完成，未构建/未真机）

五项修复（A–E），全部 TDD 落地：
**A 日期查询**与聊天正文解耦——新增 `RoomHistoryDayIndex`（metadata only：日期/边界/anchor/覆盖/schema 版本）
与 `loadMonthDays(CalendarMonth)`（本地索引优先，缺覆盖时**最多 2 次** `timestamp_to_event`、各 5s 超时，不加载正文/媒体，
不切换历史 context）；日期状态用 `RoomHistoryDayState`（knownPresent/knownEmpty/unknown/loading/error），
`unknown` 绝不显示成“无消息”且保持可点，`knownEmpty` 需证据（早于房间创建时间 / 本机连续覆盖区间 / targeted 探测结论）；
`room_page.dart` 删除 `roomLease.creationDate ?? DateTime(1970)` 兜底，最早月份改为 索引→创建时间→null；
月历页去掉 `allowUnknownPastDates` 旁路，打开/切月即读当月 metadata，切月与关闭取消在途查询（generation + 过期丢弃）；
月索引 anchor 经 `anchorForDay()` 直达定位，跳过重复 `timestamp_to_event`。
**B 全局搜索**重做为 typed 结果（`GlobalSearchResults` 联系人/群聊/聊天记录，≤3 条 + 更多入口，会话聚合），
设备侧内存索引 `GlobalSearchIndex`（不上传、不落盘、不参与 E2EE），debounce 250ms + generation 抑制过期结果；
修复“空查询把全部联系人+群名+聊天记录平铺”的旧缺陷（空查询=空态）；room+event 锚点经
`RoomOpenRequest.anchorEventId → RoomPage.initialAnchorEventId` 定位并高亮。
**C 闪照隐私**：搜索投影补 `isFlashPhoto`（修闪照混入普通媒体资产）、新增单一判据
`MediaMessageAccessPolicy` 与 `ordinaryGalleryMessages()`；普通 Gallery 数据集在构造上不含闪照，
因此邻居预取（±1）不可能触达闪照 loader；`_openImageViewerWithForward` 对闪照 fail-closed。
**D** 闪照查看时长 5s → **3s**（单一常量，代码/文案/测试同步）。
**E 屏幕捕获安全**：Android `MainActivity.kt` 新增 `FLAG_SECURE` + `secureLeaseCount` 引用计数
（首个租约开启、归零才清除、重申只重新应用）、`chatflow/screen_security` 与 `chatflow/screen_capture` 通道；
Dart `ScreenCaptureProtection`（租约幂等、平台异常静默降级）；iOS `AppDelegate.swift` 上报
`UIScreen.isCaptured`/`sceneCaptureState` 与 `userDidTakeScreenshotNotification`（只做事后销毁）。
闪照查看器：捕获中禁止 reveal（长按不消耗次数）、捕获开始/系统截图/退后台立即销毁且不回前台恢复、
动态水印、销毁态文案；**明确不声称** iOS 能阻止截图/录屏，也不对抗 root/越狱/第二台相机拍屏。
`flutter analyze lib test` 无问题；全量 `flutter test` **2826 通过 / 0 失败（退出码 0）**，
日志 `artifacts/2026-09-17/flutter-full-stage3-final.txt`（阶段二 2740）。
2026-09-17 05:46:47 +08 按用户要求构建 **0.3.92-debug/2126** 并保留数据覆盖安装 Mi 6（此前 2125），
按固定流程（源码 ARM64 debug → Apktool 2.12.1 重建 → zipalign `-P 16 -f 4` → 固定身份签名）交付，
拉回设备 `base.apk` SHA256 `7ca01bb1…ee4942` 等于候选包、证书 `75b31c66…ba61fff` 一致、
firstInstallTime 未变（2026-09-11 00:42:05）；重建验证 manifest 语义一致、类数 27316/27316、
资产/类差异 0。**未构建 iOS、未做正式发布、未部署服务端**，真机功能由用户验收。进入
[任务记录](tasks/2026-09-17-chat-history-search-flash-screen-security.md)、
[根因/验证/剩余风险](../verification/2026-09-17-chat-history-search-flash-screen-security.md)或
[2126 交付记录](../verification/2026-09-17-chat-history-search-flash-2126-mi6.md)。

## 2026-09-17 第二阶段：房间导航统一（RoomNavigationCoordinator）+ 通话身份修复（本地完成，未构建/未部署）

处理第一阶段遗留两项：① 消息列表 `MatrixHomePage._openRoom` 仍是绕过 AppHome 的第二套
RoomLease/RoomPage/路由生命周期（且用全局 `bool _openingRoom` 守卫）；② `_openCall` 仍用入口
快照里可能过期的 `contact.matrixUserId`。修复：新增 `RoomNavigationCoordinator`
（`lib/features/matrix/room_navigation_coordinator.dart`）以 **roomId** 为唯一键——
正在打开复用同一 future（不重复取租约/push）、已打开 `popUntil` 回到原页面（不 push 第二层）、
退出/异常清理登记、dispose/clear 不跨账号泄漏；`_openManagedRoom` 改为经协调器，
`MatrixHomePage` 只保留 overlay/已读/展示职责并委托 `onOpenRoom`，建群后打开也改为复用；
`_openCall` 改用新增的 `resolveCallTarget`（复用 `resolveFriendContact`），audio/video 均用权威
`matrixUserId`，`CallPage` 展示权威联系人。`DirectChatController`、
`CoordinatedDirectChatGateway`、E2EE、通话媒体链路均未改动；生产代码中
`builder: (_) => RoomPage(` 只剩 1 处（协调器打开流程），**无 legacy RoomPage 入口**。
`flutter analyze` 无问题；全量 `flutter test` **2740 通过 / 0 失败**（阶段一 2721，+19）；
4 个变异探针按预期转红。**未构建 APK/IPA、未安装真机、未部署**（用户明确本次不需要）。
风险：真实租约 revoke 时序/真机取消时长未在设备验证；建群后 revoke 实现语义等价但有微调，
建议真机回归「建群 → 退出群聊」。进入
[任务记录](tasks/2026-09-17-room-navigation-call-identity.md)或
[验证记录](../verification/2026-09-17-room-navigation-call-identity.md)。

## 2026-09-17 好友资料「发消息」统一入口 + Mi 6 Debug 0.3.92/2125（已安装，待用户真机验收）

用户报「多个好友资料入口上层实现不统一」：朋友圈/群聊走 `AppHome._openMessage`，通讯录在
`_ContactsTabPageState._openMessage` 里另有一份（直接用入口快照的 `matrixUserId`、自建
`openRoomLease` + `RoomPage` + `setOnRevoked`）。本次删除该重复实现：`ContactsTabPage` 新增
`required ContactAction onMessage` 由 AppHome 注入，`ContactsPage`/`ContactProfilePage` 保持
纯 UI + action 转发；新增 `features/matrix/direct_chat_entry.dart` 作为**唯一**身份解析与打开
去重（`resolveFriendContact` 以业务 userId 为主键，修好「Matrix ID 已更新的旧快照被误判已不是
好友」；`ensureCurrentFriendIdentity` 保留原矩阵索引契约给通话/通知/接受好友路径；
`DirectMessageOpenGate` 阻止同一好友叠加多个 RoomPage）。`DirectChatController`、
`CoordinatedDirectChatGateway`、`_openManagedRoom` 的行为未改动。
`flutter analyze` 无问题；全量 `flutter test` **2721 通过 / 0 失败**；3 个变异探针按预期转红。
2026-09-17 02:11:13 +08 按用户要求构建 **0.3.92-debug/2125** 并保留数据覆盖安装 Mi 6
（此前 2124），拉回 `base.apk` SHA256 `9fb1302d…6452c8e` 与固定证书 `75b31c66…ba61fff`
核对一致，firstInstallTime 未变；重建验证清单语义一致、资产/类差异 0。源码提交 `e0fa42c0`（未 push）。
**仅真机测试包，未做正式发布**，未构建 iOS，服务端未改动（2124 的红包总额 API 已于 00:34 部署）。
遗留：消息列表直接打开的 RoomPage 不经 AppHome，从该会话进资料再发消息仍可能叠加同一房间的
第二个 RoomPage；通话入口仍用入口快照的 matrixUserId（均见验证记录第 5 节）。
进入[任务记录](tasks/2026-09-17-unified-direct-message-entry.md)、
[验证记录](../verification/2026-09-17-unified-direct-message-entry.md)或
[2125 交付记录](../verification/2026-09-17-unified-entry-2125-mi6.md)。

## 2026-09-17 群聊转账/专属红包第三方展示 + 红包总额可见性 + 好友资料昵称（Debug 0.3.92/2124 已装，业务 API 已部署，待用户真机验收）

用户报障三项，均已按 TDD 修复：① 群聊里非收款人/非指定成员看转账与专属红包时，业务 API 本就返回
404/403，而客户端把它当加载失败 →「加载状态失败，请重试」/「无权查看该状态」+ 间歇性绿色「重试」
（15s 轮询）。修复：新增 `FinanceCardState.restricted`（403/404 只读、不轮询、不显示重试），
转账卡片显示金额 +「转给xx」、专属红包显示「给xxx的专属红包」，xx 只由**查看者本机**联系人解析
（备注 → 昵称 → 房间显示名）；发送时在 E2EE 房间消息里追加收款对象**账号标识**
（`transfer_receiver_id/_matrix_id`、`red_packet_mode/_recipient_id/_recipient_matrix_id`），
不写入任何人的备注。② 领取详情页对未领取用户显示「null 点钻」：客户端 `redPacketVisibleTotal`
隐藏空值；服务端 `RedPacketService.detail` 新增 `total_visible`（发起方 / COMPLETED / EXPIRED /
已过期未结算）并**已部署生产**。③ 好友资料页「昵称：」行改显示昵称（备注仅作标题）。
Flutter 全量 **2712 通过 / 0 失败**、`flutter analyze` 无问题；`pytest tests/business_api`
**1812 通过 / 58 跳过**；四项变异探针均按预期转红。
2026-09-17 00:35:11 +08 Mi 6 保留数据覆盖安装 **0.3.92-debug/2124**（此前 2123），
拉回 `base.apk` SHA256 `8ff43006…98c52d` 与固定证书 `75b31c66…ba61fff` 一致，firstInstallTime 未变。
源码提交 `457896c4`（基线 `5d43ce34`，未 push）。
生产 API 2026-09-17 00:34:14 +08 切换为 `starchat-business-api:redpacket-total-20260917`
（基于在线镜像单文件叠加，健康 200 / 未登录 401 / alembic head 0067 未变 / 61 键环境与 3 个挂载一致）。
**Android 仅真机测试包，未做正式发布**，未构建 iOS。进入
[任务记录](tasks/2026-09-17-redpacket-transfer-profile-fixes.md)、
[根因与验证](../verification/2026-09-17-redpacket-transfer-profile.md)或
[2124 交付记录](../verification/2026-09-17-redpacket-profile-2124-mi6.md)。
注意：旧消息（2124 之前发送）不含收款对象标识，只能显示中性文案；生产切换必须用上一版释放目录的
`frozen-api.json` + 覆盖文件，**不可**直接用 `/opt/starchat/docker-compose.yml`（其服务源码树已过期，
会丢 30 个 `BUSINESS_WALLET_*` 环境键与 2 个只读挂载）。

## 2026-09-16 四个聊天缺陷修复 + Mi 6 Debug 0.3.92/2123（已安装，待用户真机验收）

用户报障四项，均已按 TDD 修复：① 朋友圈评论选图卡死（`ImagePickerPage` 出栈 3 字段记录，
而 `moment_comment_composer`/`scan_qr_page` 用 2 字段泛型 push → 运行时 `TypeError`，路由无法
出栈，相册页卡住且编辑器锁死）；② 群聊转账出现非群成员（`room_page` 未传群成员，弹层回退到
通讯录）；③ 专属红包选指定成员报「无法确认红包账号」（未注入 `resolveBusinessUser`/
`avatarMedia`，成员投影缺业务身份）；④ 私聊转账收款人应锁定为对方。Flutter 全量 2698 通过 /
0 失败，`flutter analyze` 无问题。2026-09-16 23:29:10 +08 Mi 6 保留数据覆盖安装
**0.3.92-debug/2123**（此前 2122），拉回 `base.apk` SHA256 `5e499e8c…66abad` 与固定证书
`75b31c66…ba61fff` 核对一致，firstInstallTime 未变。该包按用户选择同时包含另一任务的登录/
会话改动（`20d4673a`）。**仅真机测试包，未做正式发布**，未构建 iOS。
进入[任务记录](tasks/2026-09-16-four-chat-bugfix.md)、
[修复验证](../verification/2026-09-16-four-chat-bugfix.md)或
[2123 交付记录](../verification/2026-09-16-four-bugfix-2123-mi6.md)。

## 2026-09-16 iOS build 2121 登录 L04/L07：device 轮换与 session 生命周期修复（本地完成，未构建/未发布）

主工作树基线 `8ef5cbac`：根因是 `MatrixLocalBinding.deviceId` 被当作身份锚点——服务端单设备策略
轮换 device（OLD→NEW）后，SDK 已把新 device 写进本地库，而 binding 未迁移，`continuityMetadata`
抛错 → `matrix_login` 阶段 **L04**；失败清理里 `suspend()` 读同一 continuity 又失败，留下
「`_accessRevoked=true` 且 client 未关闭」的半挂起态，之后 `selectAccount` 必然再失败 → **L07**
（且非空库永不清理 binding，2121 用户升级后也不自愈）。修复：① 只把 `deviceId` 从身份锚点中移除，
账号 / homeserver / Ed25519 指纹 / 库代号仍严格失败关闭；② 服务端 token 登录证明归属后原子迁移
binding（只改 deviceId），并为旧版本遗留态提供一次受同一密码学锚点约束的自愈；③ `suspend()` 重构为
「除非 client 自身 dispose 失败否则必定完成关闭」，continuity 读取失败显式标记 unknown 而非假装已验证；
④ `selectAccount` 合并为单一生命周期临界区；⑤ 新增 allowlist 诊断事件码与加盐哈希标识字段。
Flutter 全量 **2699 通过 / 0 失败（退出码 0）**，`dart analyze`（本任务 8 个文件）无问题；含一次变异
敏感性检查。**未构建 APK/IPA、未安装真机、未部署**；ADR-0072 为提案待批准，真机验收由用户执行。
进入[任务记录](tasks/2026-09-16-ios-device-rotation-l04-l07.md)或
[根因 / 验证 / 剩余风险](../verification/2026-09-16-device-rotation-binding-migration.md)。


## 2026-09-16 「清空聊天记录」误删会话修复 + 文字居中（本地完成，未构建/未发布）

主工作树基线 `8ef5cbac`：新增 `LocalHistoryClearance` 与 `history-cleared-through` 键，
把「清空聊天记录」与「删除该聊天」的截止时间信号分开，修复清空后私聊/群聊会话从消息列表
消失的问题；同时把「聊天信息」页「清空聊天记录」文字改为居中。Flutter 全量 2680 通过 /
0 失败（退出码 0），`features/matrix` 1312 通过，`flutter analyze` 无问题。

2026-09-16 22:18:11 +08，Mi 6 实际保留数据覆盖安装 **0.3.92-debug/2122**（此前
0.3.90-debug/2118），固定签名身份 `75b31c66…ba61fff` 与拉回 `base.apk` SHA256
`5153073e…fcf519d` 核对一致，firstInstallTime 未变。**仅真机测试包，未做正式发布**，
未构建 iOS。功能待用户自行真机验收。进入[任务记录](tasks/2026-09-16-clear-chat-history-room-visibility.md)、
[计划](../superpowers/plans/2026-09-16-clear-chat-history-room-visibility.md)、
[修复验证记录](../verification/2026-09-16-clear-chat-history-room-visibility.md)或
[2122 交付记录](../verification/2026-09-16-clear-history-2122-mi6.md)。

## 2026-09-12 媒体交互、访问时间与加载检查（Debug2094已安装，待用户验收）

工作树`.worktrees/offline12`分支`codex/media-interactions-20260912`基线aac3d806：最近访问缓存/刷新、图片编辑emoji与独立橡皮擦、视频/转发账号后台任务、现有点钻流水布局已由显式gpt-5.6-terra实施并经Astra亲审。2026-09-12 17:14:47+08，Mi6实际覆盖安装0.3.87-debug/2094，拉回SHA `3a15b4aa…a8bffaf`、固定证书与交付包匹配；用户功能与性能待验收。Flutter2535pass/29既有失败、mobile67pass/3既有失败、frontend161pass/11既有失败，analyze/UI契约通过；verify缺.env阻断。没有push/生产发布。进入[任务记录](tasks/2026-09-12-media-interactions.md)或[修复与交付报告](../verification/2026-09-12-media-interactions.md)继续，避免重做已完成批次。

更新日期：2026-09-10（Asia/Hong_Kong）。这里只是最近证据索引；部署前必须重新读取生产，不能把此文件当实时状态。每个任务拥有独立记录，新增任务不要覆盖其他任务条目。

| 事项 | 最近已确认状态 | 证据/下一步 |
| --- | --- | --- |
| iOS企业版 | 0.3.81/2085已发布，包SHA762fb649…37d37f2 | [发布记录](../verification/2026-09-10-ios-0381-enterprise-publication.md)；等待iPhone覆盖安装、语音、保存记录后重登反馈 |
| Android正式版 | 发布观察值0.3.80/2084；0.3.81/2085仅候选 | [2085候选](../verification/2026-09-10-platform-release-2085.md)；未获新的发布任务时不把候选自行上线；发布前核对当前API的Android platform标记兼容性 |
| 旧iOS2073更新 | 共享投影标题仍可能显示0.3.80，设备页桥接安装iOS2085 | [过渡限制](../verification/2026-09-10-ios-0381-enterprise-publication.md)；不能声称旧二进制已具有平台隔离元数据 |
| L04后续服务端修复 | 另一任务提交0b1a07c5、记录910f653e：SDK登录类型前置检查导致失败，服务端兼容公告已部署；POST仍拒绝密码型登录 | [L04追加记录](../verification/2026-09-10-mobile-0380-2084-release.md)；下一客户端版本的token-only预检查修复仍待实现，不将此待办算入既有2085包 |
| 钱包CI31失败 | fixture POSIX归属修复；Ubuntu1815通过/49跳过 | [CI证据](../verification/2026-09-10-handover-ci-ownership.md)；不需要因此重新生成既有移动包 |
| 跨会话工作流 | 根AGENTS已挂接操作手册与此索引 | [工作流](../runbooks/mobile-delivery-workflow.md)、[任务模板](task-template.md)、[本次工作流任务](tasks/2026-09-10-delivery-workflow.md) |

无新增版本/提交声称：本次工作流配置不发布APK、IPA或业务服务，不改变现有更新设置。

## Mi 6 朋友圈与聊天Debug（2026-09-11）

本任务独立分支已交付0.3.82-debug/2086到Mi 6，未生产发布。功能测试按用户要求未执行，待用户验收。[任务记录](tasks/2026-09-10-moments-im-mi6.md) · [根因与安装证据](../verification/2026-09-10-moments-im-mi6.md)。

## Mi 6 钱包重构（2026-09-11）

钱包标题保持“钱包”，TRON绑定门槛、点钻1:1零费最低10USDT提现及支付密码已实现；debug 0.3.83/2087已安装Mi 6，配套API已部署，真机交互待用户验收。[任务记录](tasks/2026-09-11-wallet-binding-payment.md) · [验证与实际镜像](../verification/2026-09-11-wallet-binding-payment.md)。此条仅代表本任务观察，不覆盖其他任务发布条目。

## 2026-09-11 性能专项

| 事项 | 状态 | 证据 |
| --- | --- | --- |
| 性能专项 Android/iOS | Astra 实际差异审查、显式 Terra 执行已完成本地性能批次；Flutter 2199通过/29钱包用例失败，全量分析及Android arm64源码编译通过；全量验收仍未通过，iOS原生与真机待验收；未push/部署/生产操作 | [任务记录](tasks/2026-09-11-performance.md) · [本地验收记录](../verification/2026-09-11-performance-local-acceptance.md)；无新版本安装或发布 |

## 2026-09-11 红包、转账与点钻账单（本地实现与审查完成，真机待验收）

当前performance工作树中的红包/转账/点钻账单实现与本地审查完成，Astra主审、显式gpt-5.6-terra实施。真实入口/详情/账单/群人数定向验证通过；全Flutter2310通过/29基线失败，analyze和ARM64源码编译通过。全仓其他既有失败与未验证真机/多端见报告；未发布或安装新版本。[任务记录](tasks/2026-09-11-finance-chat.md) · [计划与验收用例](../superpowers/plans/2026-09-11-finance-chat.md) · [审查记录](../verification/2026-09-11-finance-chat-review.md)。


## 2026-09-11 main合并、跳板部署与Mi 6 Debug2088

全部本地分支已合并到main并推送，源代码候选6be55572；生产API候选a397ecd9已通过跳板部署，8API/13静态文件、健康/鉴权/哈希/隔离恢复通过，未迁移DB。Mi 6实际覆盖安装0.3.84-debug/2088，固定签名与已安装原包一致，实际APK哈希bd7c1e97…de0aebb，原数据未清除。Flutter2344通过/29既有钱包失败、analyze通过，用户真机测试待验收。此次记录更新之前的未发布状态，仅覆盖本次明确范围，Android/iOS正式更新设置未修改。[任务](tasks/2026-09-11-integrate-deploy-mi6.md) · [交付报告](../verification/2026-09-11-integrate-deploy-mi6.md)。

## 2026-09-12 消息选区与动态emoji Debug2089

Astra审查、显式gpt-5.6-terra实施；本地分支codex/chat-selection-20260912源码48fe7475。0.3.85-debug/2089已覆盖安装Mi6，固定签名与拉回APK哈希核对通过。定向Flutter61/61、分析、HTML12/12通过；全量仍有29 Flutter与11前端既有失败，verify缺.env。未push或部署生产；功能手感待用户验收。[任务](tasks/2026-09-12-selection-emoji-repair.md) · [交付与限制](../verification/2026-09-12-selection-emoji-repair.md)。

## 2026-09-12 断网恢复、离线缓存与页面提示 Debug2093

Astra亲审、显式gpt-5.6-terra执行完成。工作分支`codex/offline-recovery-20260912`源码`01d6df58`整合main`1d1db6aa`，保留已安装2092的好友在线状态/平台下载链接；0.3.86-debug/2093已在Mi6保留数据安装，原签名与拉回APK完整SHA一致。最终Flutter2453通过/29既有钱包失败，分析通过；HTML/边界已有失败与verify缺.env如实记录。真实断网恢复≤5秒、iOS、多端及性能由用户继续验收；未push/部署/迁移。[任务记录](tasks/2026-09-12-offline-recovery.md) · [根因、验证、安装与用户用例](../verification/2026-09-12-offline-recovery.md)。


## 2026-09-12 历史日期检索、滚动与群聊接收延迟（进行中）

用户确认Mi6 Debug0.3.87/2096接收迟缓。当前codex/history-latency-20260912在offline12工作树合并2094与root main2096输入，尚未完成验证或发布；显式gpt-5.6-terra串行执行，Astra审查。日期整月串行回溯已定位，历史滚动复现和接收分层测试进行中；不把服务器当前低耗时当作实际事故归因。 [任务记录](tasks/2026-09-12-history-latency.md) · [计划](../superpowers/plans/2026-09-12-history-latency.md)。

## 2026-09-12 23:36 历史检索/接收延迟（部分修复，执行与版本整合阻塞）
工作树`.worktrees/offline12`、分支`codex/history-latency-20260912`：I0合并2094+2096为9e87c8a0，H2历史滚动修复bc7ca46a，H3真实SQLite量化27883fa8。H2定向24通过；全量Flutter2555/29、mobile67/3、frontend161/11，失败身份无新增；verify缺.env。日期检索H1及同步阶段计时尚未实现：显式Terra预算耗尽、新代理thread limit、CLI只读model probe认证401。Mi6已被另一路更新2099（23:17:37），本任务未构建/安装/覆盖；后续需对齐新版本并恢复Terra执行。进入[本任务记录](tasks/2026-09-12-history-latency.md)和[计划](../superpowers/plans/2026-09-12-history-latency.md)继续。
该任务最终追加：65e94cda清理旧fixture warning，af426a3b完成fragment token小修；Astra44项相邻回归通过、全量analyze无问题，最终Flutter2556通过/29既有失败。日期UI/定位capability及真实50秒延迟仍未完成；详见[当前报告](../verification/2026-09-12-history-latency.md)。

## 2026-09-13 账单/转账与历史整合 Debug2104（已安装，待用户验收）
Astra亲审、明确gpt-5.6-terra执行完成，本地分支codex/finance-history-2103-20260913源码e314d4f0整合main e2870554和既有H2。指定HTML账单/转账样式、按需日期检索与双向历史拖动保护已实现；同步阶段数字诊断已加入，但50秒接收延迟未定因。Mi6于03:21:25+08保留数据安装0.3.87-debug/2104，03:22:13拉回SHA260370f6…39b8bc9及固定证书一致。全Flutter2602通过/29旧钱包失败、mobile70通过、UI契约28/364通过、全分析无问题；frontend161/11旧失败，verify缺.env。未push/生产部署，用户自行真机测试。见[任务记录](tasks/2026-09-13-finance-history-2103.md)、[完整交付报告](../verification/2026-09-13-finance-history-2103.md)和[计划](../superpowers/plans/2026-09-13-finance-history-2103.md)。


