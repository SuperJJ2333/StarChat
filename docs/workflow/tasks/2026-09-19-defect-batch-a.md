# 任务记录：畅聊缺陷清单 0917 · 批次 A 客户端快修（2026-09-19）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-19 批准《畅聊缺陷清单 0917 修复计划》（`docs/superpowers/plans/2026-09-19-defect-batch-0917-fix-plan.md`）并拍板全部 7 个决策点（D1 按钮取消/确定、D2 专用 403 仅密码正确时、D3 转移给最早成员、D4 验证前可改邮箱、D5 不做暂停、D6 一期轮询、D7 连播默认开）。本批次只做批次 A（客户端快修 10 项，覆盖缺陷 BUG-11/14/15/16/20/22/25/27/30/32）；批次 B/C 未开工。
- 关联计划/ADR：同上；关联 `docs/畅聊缺陷清单-0917-标准化.csv`（状态随本任务回填）。
- **批次 B 扩展（用户 2026-09-19 指令 + 真机回归反馈）**：本任务扩展承接批次 B 的客户端可回归项与真机反馈修复：
  - 真机反馈 F1（BUG-11 回归）：拉黑用户仍能发消息提醒 → 通知层 `_isNotifiableMessage` 对拉黑发送者抑制 + 会话列表未读归零（`blockedContacts` 投影）。服务端拒收属服务端改造，另列。
  - 真机反馈 F2（BUG-14 回归）：气泡无点击动效 → 改 CupertinoButton（按压透明动效）+ 回拨 toast「正在发起…通话」。
  - 真机反馈 F3（BUG-20 回归）：草稿延迟 10 秒+全列表卡顿 → 改逐 tile `ValueListenable` 通知器（room_page 保存即更新对应 tile；撤销 home 全列表 setState）。
  - 真机反馈 F4（BUG-32 回归）：引用图标改双引号字形「””」（用户指定微信式；_presentation 改为 Widget 型）。
  - BUG-23：CallPage 新增 onEnded(roomId)（_popOnce 单次触发）+ 会话能力 `markRoomRead`（setReadMarker 至最新事件 + 清 manualUnread）；主叫/来电两条路径接线。
  - BUG-29：群主退出前转移给最早加入成员（D3）；转移失败不退出。
  - BUG-24 补齐：GroupAutoJoinFailure 带 code；`GROUP_INVITEE_UNAVAILABLE` → 「该账号已被限制，无法加入群聊」+ 撤回 Matrix 邀请（网关 withdrawInvite=room.kick）。
  - BUG-19（服务端+客户端）：登录在密码正确但账号非 ACTIVE 时返回 403 `ACCOUNT_SUSPENDED`（密码错误仍 401 防枚举）；客户端透传文案；登录期 403 豁免会话失效（business_api_client）。
  - BUG-21（服务端）：friendship accept 幂等合并互为申请（好友已存在则不重复插入，联系方式偏好仍落库，audit=friend.accepted.merged）。
  - **BUG-12 已实施（用户批准 D4；ADR-0074）**：服务端 `EmailVerificationService.change_email` + 端点 `POST /auth/registrations/{session}/email`（作废旧挑战/更新邮箱/新码发新邮箱/会话不变；409 EMAIL_ALREADY_REGISTERED；已验证账号拒绝）；客户端网关+controller.changeEmail+验证页原地弹窗换邮箱（不再退回注册页）。服务端测试 test_registration_email_change.py 3 项绿。
  - **第二轮真机反馈（2026-09-19 晚）**：
    - 反馈 1（拉黑后仍能收到消息）：改为 Matrix 标准忽略列表方案——服务端 `/blocks` 附带 `matrix_user_id`（join users 表），app_home 拉黑投影水合后同步 `client.ignoreUser/unignoreUser`（Synapse 同步层过滤，消息不再送达本机）；运行时拉黑/取消拉黑经投影监听增量同步（`_blockAutoIgnored` 追踪本 App 自动忽略的账号，取消拉黑只移除这些）。未读抑制改按 `isMatrixIdBlocked(directPeerId)`。服务端测试 `test_blocks_projection_includes_matrix_user_id`。
    - 反馈 2（失败气泡退回重进后排到底部）：根因 = `restoreOutboxMessage` 复用 `_localTimestampFor` 把 createdAt 钳位到最新消息之后，且恢复行只 append。改为保留原始 createdAt + 恢复时按时间戳插入历史位置。红→绿：offline_send_state_test「BUG 回归」用例。
    - BUG-12 服务端与客户端实施完成（见上）；二次部署覆盖三文件最新版（容器内 md5 与本地一致：service 6516f338 / identity 59bd7e76 / registration 32c49d65），容器 healthy。
  - **第三轮（第二批回归反馈，2026-09-19 晚）**：
    - 反馈 1（BUG-20 草稿会话不上浮）：RoomDraftStore 增加 `draftRoomIds` + `draftMembershipRevision`（仅进入/离开草稿态递增，正文编辑不触发重排）；matrix_home 排序改为 置顶 → 草稿 → 普通三段（微信语义）。红→绿：tile_draft 测试成员修订用例。
    - 反馈 2（取消拉黑后通话/提醒不恢复）：`_syncMatrixIgnoreList` 改为**忽略列表与拉黑列表严格镜像**（不在拉黑集合中的一律移出忽略列表），消除跨重启残留；登出清空投影时跳过同步（不得误清服务端忽略数据）。
    - 反馈 3（BUG-23 未读仍 4 条）：`onEnded` 原挂在 `_popOnce`——来电页（autoCloseOnEnd=false）与最小化路径永不触发。改为 `_changed` 中终态首次出现即通知（终态粘性：控制器终态后忽略 connected，单次通知即正确）。抖动测试改接通前置。红→绿：call_page_test 3 用例（含来电页路径与粘性断言）。
    - 最终包：chatflow-debug-0.3.96-2134-batch-b4.apk（18:01 装 MI 6）。
  - **第四轮（第二批回归反馈 2 追加，2026-09-19 晚）**：拉黑后对方仍能发消息——运行时 `markBlocked` 只登记业务 ID，而忽略列表同步/通知抑制/未读抑制按 Matrix ID 判定 → 拉黑要等下次启动水合才生效。修复：`BlockedContacts` 重构为业务 ID ↔ Matrix ID 双投影（`matrixIdByUser` 映射 + `markBlocked/markUnblocked` 可选携带 Matrix ID + `isMatrixIdBlocked`），contacts_page 拉黑/取消拉黑时就地补记（立即生效，不等水合）；服务端 /blocks 已返回 matrix_user_id（已部署）。测试：新增 blocked_contacts_test 4 用例（红→绿）。最终包 batch-b5（18:14 装 MI 6）；全量 flutter test 3508 全绿。
  - **批次 C（体验增强，2026-09-19 晚）**：
    - BUG-03 补齐：通讯录右侧字母条 `top` 锚定 `contactTileHeight*3`（三个功能入口行之下，微信语义）。
    - BUG-38：封面更换四步链路整体最多自动重试一次（800ms 退避）；最终失败改为 toast「封面更换失败，请重试」，不再向查看器裸抛原始报错。
    - BUG-39（D6 一期）：转账详情 `ChatTransferDetailController` 内置 PENDING 静默轮询（默认 5s，可注入）；状态离开 PENDING 即停并回调 `onPeerSettled`（页面 toast「这笔转账对方已处理」）；轮询失败静默。测试 2 项（自动刷新+终态停轮询）。
    - 未列入本批：BUG-28（图片尺寸）、BUG-35（相册视频进度）、BUG-40（语音连播）——涉及媒体/SDK 深层与开关设置，转下一批。
  - **第五轮（第三批回归反馈 + 红包限额，2026-09-19 深夜）**：
    - BUG-03 跳转修复：分组头挂 GlobalKey，`_jumpTo` 改两段式（估算偏移动画 → 懒加载完成后按真实位置 ensureVisible 校正），修复"点击字母无法跳转"。
    - 转账/红包卡片「重试」按钮移除（用户指令）：失败态点击卡片本身即重试（finance_message_card 两个分支），测试契约同步修订。
    - BUG-41：朋友圈页 `showNetworkCapsule: false`——内容离线优先可完整使用，不再渲染常驻网络状态栏（WeChatPageScaffold.navigation 新增开关，默认 true 不影响其他页面）。
    - 红包限额 200.00（用户指令，前后端统一）：服务端 config 默认 20000→200.00（已部署+重启）；生产 DB 无覆盖行（已查证）；客户端表单默认与提示同步 200。服务端测试/表单测试全绿。
    - 最终包 batch-c2（19:01 装 MI 6）；全量 flutter test 3515 全绿。
  - **生产部署（2026-09-19，用户授权）**：business-api 容器 starchat-business-api-1 最小覆盖三文件（friendship/service.py、api/identity.py、identity/registration.py）。备份 /opt/starchat/backup-20260919-defect-batch-b/（3 原文件+镜像 ID sha256:026f6dbc…）；上传件 SHA256 与本地一致；docker cp+restart 后容器 healthy、登录错误凭证仍 401 原口径、新端点存在（422=缺参）、近 5 分钟日志 0 error。注意：容器被重建（镜像重拉）会丢失覆盖层，需按本次记录重新覆盖或固化为新镜像 tag。
  - 服务端测试：friendship 54 项、identity 8 项全绿（.venv pytest）。
- 当前状态：实现完成、定向测试全绿、全量 3466/1（唯一失败归属并行会话编辑中间态）。CSV 批次 A 状态已回填（主文件被 Excel 占用，更新副本在 artifacts/2026-09-19/）。
- 负责人、工作树、文件所有权、源码commit：基于 37b2cb3d 之后的并行提交（b308598d 等）。本批次文件：`lib/ui/chat/message_action_sheet.dart`、`lib/ui/chat/wechat_call_bubble.dart`、`lib/ui/chat/conversation_action_sheet.dart`、`lib/ui/chat/wechat_image_editor.dart`、`lib/ui/components/conversation_list_tile.dart`、`lib/ui/foundation/changliao_icons.dart`、`lib/features/contacts/contacts_page.dart`、`lib/features/contacts/request_friend_page.dart`、`lib/features/matrix/call_page.dart`、`lib/features/matrix/matrix_e2ee_client.dart`（clearUnread mutation）、`lib/features/matrix/matrix_home_page.dart`、`lib/features/matrix/matrix_client_factory.dart`（无改动，略）、`lib/features/matrix/group_chat_controller.dart`、`lib/features/matrix/room_draft_store.dart`、`lib/features/matrix/room_page.dart`；测试：`contacts_bug_0917_test`、`message_action_sheet_test`、`request_friend_page_test`、`wechat_image_editor_test`、`wechat_call_bubble_test`（新）、`call_page_test`、`group_chat_controller_test`、`conversation_action_sheet_test`、`anchored_action_menu_test`、`conversation_tile_draft_test`（新）。
- 最后更新时间（含时区）：2026-09-19T13:10+08:00
- 下一条具体操作、必要输入、阻断的验收 ID：全量 flutter test 结果回填；提交（用户未授权前不代提交）；真机回归（批次 A 全部 10 项 + 批次 R 清单）由用户执行。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A-BUG-11 | 拉黑确认框按钮「取消/确定」 | contacts_page.dart confirmLabel='确定' | contacts_bug_0917_test（红→绿） | 未发布 | 待真机 |
| A-BUG-32 | 引用动作使用引用气泡图标 | message_action_sheet reply→quote_bubble | message_action_sheet_test 新用例（红→绿） | 未发布 | 待真机 |
| A-BUG-30 | 重复申请提示「已申请过」 | request_friend_page 消费 duplicate 响应 | request_friend_page_test 新用例（红→绿） | 未发布 | 待真机 |
| A-BUG-25 | 编辑态收藏/保存提示 3 秒消失 | wechat_image_editor _showTransient（瞬态与错误分离） | wechat_image_editor_test 新用例（红→绿） | 未发布 | 待真机 |
| A-BUG-27 | 转发接受后显示瞬态「已转发」，不再滞留「正在发送」 | 同上（forward 分支改瞬态提示；编辑器保持打开） | 改写固化旧缺陷的测试 + 新断言（红→绿） | 未发布 | 待真机 |
| A-BUG-22 | 视频来电接听按钮为视频图标 | changliao_icons.videoCallFilled + call_page 按 type 分支 | call_page_test 新用例（红→绿） | 未发布 | 待真机 |
| A-BUG-14 | 通话气泡区分语音/视频 + 点击回拨 | wechat_call_bubble 按 video 分支图标文案 + onRedial；room_page 直聊注入回拨（复用 onVoice/onVideo） | wechat_call_bubble_test 4 用例（新，红→绿） | 未发布 | 待真机（群聊点击不动作） |
| A-BUG-16 | 聊天信息页发起群聊默认选中对端（可取消） | GroupChatController.preselectedMatrixUserIds（load 时与通讯录求交）+ RoomPage.onCreateGroupWithPeer + app_home 传参 | group_chat_controller_test 2 新用例（红→绿） | 未发布 | 待真机 |
| A-BUG-15 | 已标未读显示「取消未读」，选择后清除 | sheet 增加 manualUnread + clearUnread 动作 + MatrixConversationMutation.clearUnread | conversation_action_sheet_test 新用例（红→绿）；anchored_action_menu_test 适配 | 未发布 | 待真机 |
| A-BUG-20 | 有草稿的会话列表显示红色「草稿：」标识 | RoomDraftStore 进程内预览索引（recordDraftPreview/draftPreview/previewsRevision）+ tile draft 渲染 + room_page 登记 + home 监听刷新 | conversation_tile_draft_test 3 用例（新，红→绿） | 未发布 | 待真机；冷启动后未经会话的旧草稿无预览（存储扫描列为后续优化） |

批次 R（19 项已修复回归）与批次 B/C 未在本任务范围。

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| flutter analyze | 1 issue（并行会话 conversation_list_restart_recovery_test 未用导入，非本任务文件）；本批次文件 0 问题 | 工作树（基线 37b2cb3d 后的并行提交） | - | - | - |
| 定向测试 | contacts_bug_0917(5)/message_action_sheet(3)/request_friend(6)/image_editor(7)/call_bubble(4 新)/call_page(7)/group_chat_controller(7)/action_sheet(2)/anchored_menu(2)/tile_draft(3) 全绿 | - | - | 全量日志 docs/verification/artifacts/2026-09-19/batch-a-full-test.log | - |
| 全量 flutter test | **3466 通过 / 1 失败**；唯一失败 = local_conversation_delete_test（该测试文件由并行会话于 15:00 修改中，非本批次文件，判定为其编辑中间态） | - | - | docs/verification/artifacts/2026-09-19/batch-a-full-test.log | - |

环境：Windows 10（win32 10.0.19045）、Flutter `C:\src\flutter`、pub 镜像 pub.flutter-io.cn。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 计划核实（3 代理逐条） | 2026-09-19T11:2x | 11:5x | 外部等待=代理 | 3 组并行 | 会话记录 | - |
| 批次 A 实现（TDD 逐项） | 12:4x | 13:0x | 返工：BUG-27 首版 pop 方案破坏导出 harness → 改瞬态提示（计划内备选）；BUG-25 测试时序需 runAsync | - | 会话记录 | - |
| 门禁 | 13:0x | 进行中 | - | - | - | 回填 |

## 交接与回退

- 已确认根因/已排除假设：见计划文档各条目（均带 file:line）。
- 待办及验收失败项：批次 B（BUG-12/19/21/23/24/29，跨端）、批次 C（BUG-03/28/35/38/39/40）；并行会话的 identity resolver 工作与本批次共享 matrix_e2ee_client.dart/room_page.dart，提交顺序需协调。
- 已发布与仅候选的区别：本批次为未发布源码变更，无构建无发布。
- 生产备份位置、恢复操作：不适用（未触碰生产）。
- 运行中CI/命令：无。
- 下次恢复先检查的事实：全量测试日志（artifacts/2026-09-19/batch-a-full-test.log）失败归属；并行会话是否已提交（避免双提交冲突）；CSV 状态列是否已回填批次 A。
