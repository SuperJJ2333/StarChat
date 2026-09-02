# 计划：聊天红包弹窗/@面板/拍一拍视角/气泡昵称打磨（2026-08-29）

对应需求批次（6 项）：气泡昵称、红包领取弹窗、開字按钮与手气详情、@面板、拍一拍视角文案、发红包页背景色。

## 边界与不变式

- 备注（remark）仅存于业务侧联系人数据，是"设置者本人"的本地视图；所有"他人视角"渲染不得使用备注。
- 红包资金状态一律来自 Business API（`/red-packets/*`），Matrix 事件只承载引用（packet_id）。
- "手气最佳"由客户端按 claims[].amount 最大值计算（后端无该字段）。

## 改动文件

| 文件 | 变更 |
| --- | --- |
| `lib/ui/foundation/wechat_tokens.dart` | 新增发红包页浅色渐变/文字 token（保留领取弹窗红色 token） |
| `lib/features/matrix/chat_red_packet_sheet.dart` | F6：创建页背景改浅色主题，深色文字 |
| `lib/ui/chat/wechat_message_bubble.dart` | F1：新增 `senderName` 入参，incoming 气泡上方 12pt #999999 昵称，与气泡左缘对齐 |
| `lib/features/matrix/room_timeline_controller.dart` | F5：VM 增加 `nudge` 载荷（NudgeInfo） |
| `lib/features/matrix/matrix_room_timeline_adapter.dart` | F5：nudge 事件改为携带结构化载荷而非成文文案 |
| `lib/features/matrix/message_interaction_service.dart` | F5：`formatNudgeNotice` 纯函数（视角区分、隐私规则）；F4：`MentionDraft.appendAll` |
| `lib/features/matrix/matrix_home_page.dart` | F1/F4/F5 接线；F2：红包卡片点击改弹领取弹窗；@触发监听 |
| `lib/features/redpacket/red_packet_controller.dart` | 抽 `RedPacketViewGateway`（detail/claim）便于测试 |
| `lib/core/business_api_client.dart` | implements `RedPacketViewGateway` |
| `lib/features/redpacket/red_packet_claim_dialog.dart` | F2：居中缩放弹窗（0.25s ease-out）+ 毛玻璃背景 + 弹窗下方 X + 点外部关闭 + 「開」+ 「看看大家的手气>」 |
| `lib/features/redpacket/red_packet_claim_detail_page.dart` | F3：领取详情页（总额/个数/发送者/记录列表/手气最佳徽章） |
| 删除 `lib/features/redpacket/red_packet_detail_sheet.dart` | 被新弹窗+详情页取代 |
| `lib/ui/chat/chat_composer_state.dart` | F4：`ComposerPanel.mention` |
| `lib/ui/chat/wechat_mention_panel.dart` | F4：选择提醒的人面板（搜索、A-Z 排序、两行展示、所有人置顶） |

## 排序与隐私决策

- A-Z 排序复用通讯录既有约定：取主名首字符，A-Z 分组，非拉丁字母落入 `#`（与 contacts_page `ContactIndex` 一致；仓库无拼音依赖）。
- 群主/管理员判定复用 `groupChatAccountDataType` 账号数据（owner_id / admin_ids，回退 m.room.create sender）。
- 拍一拍：本人视角目标用 备注>实时昵称；他人视角双方仅用实时昵称（不查备注），后缀照常展示。
