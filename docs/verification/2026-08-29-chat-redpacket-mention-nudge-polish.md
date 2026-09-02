# 聊天红包弹窗/@面板/拍一拍视角/气泡昵称打磨 — 验证证据（2026-08-29）

需求批次：6 项（气泡昵称、红包领取弹窗、開字按钮与手气详情、@面板、拍一拍视角文案、发红包页背景色）。
计划：`docs/superpowers/plans/2026-08-29-chat-redpacket-mention-nudge-polish.md`。

## 1. 实现摘要

### F1 气泡上方发言人昵称
- `lib/ui/chat/wechat_message_bubble.dart` 新增 `senderName` 入参：仅 incoming 消息在气泡上方渲染，12pt、`WeChatColors.messageSenderName`（#999999）、左侧缩进 48px（头像 40 + 间距 8，与气泡左缘对齐）、单行省略、与气泡间距 3px。
- `matrix_home_page.dart` 传入 `message.isOwn ? null : displayName`（本人消息不显示）；显示名沿用 `resolveMessageSenderDisplayName`（备注 > Matrix 昵称 > mxid），群聊与私聊均生效。

### F2 红包领取弹窗
- 新增 `lib/features/redpacket/red_packet_claim_dialog.dart`：`showGeneralDialog` 居中弹窗，缩放 0.6→1.0 + 淡入，250ms `easeOutCubic`；全屏 `BackdropFilter`(sigma 14) + `#66000000` 遮罩实现毛玻璃；弹窗下方居中 X 关闭按钮；点击弹窗外任意区域关闭；卡片 272 宽、圆角 16、红色渐变、投影，与微信领取弹窗一致。
- 卡片内容：发送者头像+「{昵称}的红包」、祝福语、金色圆形「開」按钮（key `red-packet-claim-open-button`）、下方「看看大家的手气 >」入口、领取成功显示「已领取 x.xx 点钻，存入点钻余额」、业务错误内联展示。
- 旧 `red_packet_detail_sheet.dart` 已删除，红包卡片点击改为弹出该弹窗。

### F3 领取详情页
- 新增 `lib/features/redpacket/red_packet_claim_detail_page.dart`：顶部卡片（发送者头像/昵称、`共 {total} 点钻，已领取 {claimed}/{share} 个`、非 OPEN 状态文案）+ 领取记录列表（按 claimed_at 升序）。
- 每条记录：头像、昵称（备注 > 昵称，来自查看者自己的通讯录，`GET /friends`）、金额「xx点钻」、金额最高者（并列取最早）标注「手气最佳」描边徽章；分隔线左缩进 62。
- 纯函数 `parseRedPacketClaims` / `bestLuckRecordIndex` 可独立测试（后端无手气最佳字段，由客户端计算）。

### F4 @ 选择提醒的人
- `ComposerPanel` 新增 `mention`；`matrix_home_page` 监听输入框：群聊文本以 `@` 结尾时弹出面板，文本变化后自动关闭。
- 新增 `lib/ui/chat/wechat_mention_panel.dart`：顶部搜索框（范围=备注+昵称）、A-Z 排序（主名首字符，非拉丁入 `#` 桶排尾，与通讯录 `ContactIndex` 约定一致、仓库无拼音依赖）、成员两行展示（第一行备注否则昵称；第二行 12pt #888888 昵称，仅存在备注时显示）、群主/管理员固定首项「所有人」。
- `MentionDraft.appendAll`：「@所有人」标记映射全部成员 id，发送时经既有 `activeUserIds` 注入 `m.mentions.user_ids`；成员排除本人。
- 群主/管理员判定与群设置页同源：`groupChatAccountDataType` 的 `owner_id`/`admin_ids`，回退 `m.room.create` sender。

### F5 拍一拍视角文案
- `RoomMessageViewModel` 新增 `NudgeInfo` 结构化载荷（adapter 不再成文）。
- 纯函数 `formatNudgeNotice`：本人拍出→「我拍了拍{备注>实时昵称}」+后缀；他人拍出→「{拍人者实时昵称}拍了拍{被拍者实时昵称}」+后缀，且签名上只有本人视角参数接收备注，结构上防止备注泄露。
- 事件内快照名作为实时名缺失时的回退。

### F6 发红包页背景色
- `chat_red_packet_sheet.dart` 背景改为品牌绿浅色调渐变 `redPacketCreateGradientTop #E7F5EA → redPacketCreateGradientBottom #F6F7F8`（新增 token），导航栏同色深字，类型选择器/提示文案改深灰/品牌绿，视觉柔和、无高饱和暖色。
- 领取弹窗仍保留微信式红色主题（spec 仅约束创建页）。

### 其他
- `RedPacketViewGateway` 接口抽取（detail/claim/listContacts），`BusinessApiClient` implements，控制器与页面可注入伪造实现。
- 测试契约同步：`chat_red_packet_sheet_test.dart` 背景断言改为新浅色 token。

## 2. 测试结果

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| Flutter 静态分析 | `flutter analyze` | No issues found |
| Flutter 全量测试 | `flutter test` | **347 passed**（新增 26 项） |
| 仓库全量校验 | `pwsh -NoProfile -File scripts/verify.ps1` | **Verification: PASS**（matrix-bot 9、business 215+1 skipped、Flutter 边界 21、UI 合同漂移 17 组件/330 屏、迁移/OpenAPI/Compose 渲染 PASS） |

新增测试文件：
- `test/ui/wechat_message_bubble_sender_name_test.dart`（3 用例：显示/本人不显示/无名字）
- `test/ui/wechat_mention_panel_test.dart`（7 用例：排序、搜索、两行、置顶、回调、搜索过滤、次行样式）
- `test/features/matrix/nudge_notice_format_test.dart`（4 用例：本人视角备注、回退、他人视角不泄露备注、快照回退）
- `test/features/redpacket/red_packet_claim_dialog_test.dart`（5 用例：居中/開/手气入口、领取成功、错误内联、点外/X 关闭、跳转详情）
- `test/features/redpacket/red_packet_claim_detail_page_test.dart`（5 用例：解析排序、手气最佳计算、总额/发送者/记录、空记录、过期状态）

## 3. 隐私与资金边界核对

- 备注仅来自查看者本人 `GET /friends` 数据；他人视角拍一拍文案与红包记录不读备注以外的他人资料，备注不进入 Matrix 事件内容。
- 红包金额/领取状态全部来自 Business API（`GET /red-packets/{id}`、`POST /red-packets/{id}/claims`），Matrix 事件仅承载 `packet_id` 引用；未新增任何从 Matrix 状态推导资金的路径。

## 4. 遗留事项（非阻塞）

- 「@所有人」当前映射为全部成员 id 注入 `m.mentions`；如需与服务端房间级提及（`m.mentions.room`）对齐可后续切换。
- 红包领取弹窗的缩放动画在手势模拟测试中以路由过渡覆盖，未做逐帧断言。
