# 畅聊缺陷清单 0917 · 更新修复计划

> 依据：`docs/畅聊缺陷清单-0917 - 缺陷清单.csv`（41 项有效缺陷，BUG-42~55 为空占位行）
> 核实方法：三个并行探索代理逐条对照当前代码（HEAD `b308598d`）核实，全部结论带 file:line 证据。
> 标准化清单：`docs/畅聊缺陷清单-0917-标准化.csv`（本计划的状态总览与之一一对应）。
> 状态：**待用户批准**。批准后按批次执行，遵守 `docs/runbooks/mobile-delivery-workflow.md`（TDD 先红后绿、flutter analyze + 全量 flutter test + verify.ps1、独立任务记录、debug 包交 MI 6 由用户自测）。

## 一、状态总览

| 状态 | 数量 | 编号 |
|---|---|---|
| 已修复·待真机回归 | 19 | BUG-01,02,04,05,06,07,08,09,10,11,13,17,26,31,33,34,36,37,41 |
| 已具备·无需开发 | 1 | BUG-18（管理端解封 API 与后台面板已存在） |
| 部分修复·待补齐 | 5 | BUG-03,24,28,30,35 |
| 未修复·已排期 | 15 | BUG-12,14,15,16,19,20,21,22,23,25,27,29,32,38,39 |
| 需求增强 | 1 | BUG-40 |

CSV 原始「修复情况」列只标注了 5 项（BUG-01/02/04/05/06），其余 15 项"已修复"是本次逐条核实确认的，需在清单中回填。

## 二、批次 R：真机回归清单（不改代码，随下个 debug 包验收）

以下 19 项已有代码修复与测试证据，统一在下一个交付包上做真机回归，并回填 CSV「回归验收」列：

| 编号 | 场景 | 关键证据（代码/测试） |
|---|---|---|
| BUG-01 | 注册页输错邀请码只出 1 条提示 | registration_controller.clearInvitationCodeError（bug-01-10 批次） |
| BUG-02 | 登录页可查看用户协议/隐私政策 | 同上批次 |
| BUG-04 | 邀请链接浏览器可打开（服务端路由） | 同上批次（0.3.96 正式包标注） |
| BUG-05 | 我的页保存有成功提示 | 同上批次 |
| BUG-06 | 全部账单筛选样式/日期分组/重置 | formatLedgerFilterDate 等（同上批次） |
| BUG-07 | 勿扰模式无「PRDS30」残留文字 | 同上批次 |
| BUG-08 | 减少动态效果设置生效（MotionPageRoute 全量替换） | _MotionSettingsTile（同上批次） |
| BUG-09 | 加好友时新建标签能进标签列表 | request_friend_page_test「new tags…server-side」 |
| BUG-10 | 黑名单开/关立即生效且重启保持 | blocked_contacts 投影 + blockList()/unblockContact() |
| BUG-11 | 拉黑确认框按钮不再是「删除」 | contacts_page.dart:1084-1090（文案「加入」）＋ contacts_bug_0917_test.dart:177 |
| BUG-13 | 新的朋友头像正常 | contacts_page.dart:2027-2032 + user_avatar 兜底 |
| BUG-17 | 置顶会话背景色有区分 | conversation_list_tile.dart:57-60（浅 #EDEDED/#FFF，深 #191919/#232323） |
| BUG-18 | 管理后台可直接解封 | admin.py:172-180 POST /security/bans/{id}/revoke |
| BUG-26 | 编辑态转发到群显示群九宫格头像 | room_page.dart:4323-4344 GroupAvatarMosaic |
| BUG-31 | 申请好友页已按微信风格重构 | request_friend_page.dart:19-441 + 布局测试 |
| BUG-33 | 消息提醒到点触发本地通知 | message_reminder_service + local_notification_scheduler（6 用例） |
| BUG-34 | 语音条滑到「转文字」生效 | voice_transcriber.dart（依赖系统 STT，见风险） |
| BUG-36 | 选表情后直接点发送一次成功 | room_page.dart:5194-5204 TapRegion 不消费事件 |
| BUG-37 | 搜索聊天记录头像不显示「?」 | matrix_e2ee_client.dart:6491-6498 senderName 兜底 |
| BUG-41 | 朋友圈大图「正在加载」不再滞留 | moment_image_viewer_page.dart:224-228 + 胶囊随页销毁 |

## 三、批次 A：客户端快修（P0/P1 小项，预计 2~3 人日）

每项均 TDD：先写失败用例（红）→ 最小实现（绿）→ analyze + 相关测试。文件所有权互不重叠，可多批并行。

### A1 BUG-25 编辑态收藏/保存提示不消失
- 根因：`wechat_image_editor.dart:786-791` 把成功提示写进常驻错误字段 `_error`，无定时清除。
- 方案：收藏/保存成功改用自动消失提示（复用 3 秒 Timer 模式，参照 room_page.dart:2170-2182），不占用错误字段。
- 测试：编辑器 widget 测试——收藏后提示出现、 pump 3 秒后消失；错误信息仍常驻。

### A2 BUG-27 编辑态转发后一直「正在发送」
- 根因：编辑器 `_error='正在发送'`（:787-791）后无终态更新；真正的完成提示发给了底下的会话页。
- 方案：把编辑器的转发提示接到转发 job 终态（`_trackForwardJobs` 完成回调）——完成后编辑器内改显「已转发」（3 秒消失），失败显示「转发失败」；同步修订固化旧行为的 `wechat_image_editor_test.dart:179-197`。
- 测试：转发成功/失败两条用例（编辑器内终态可见、自动消失）。

### A3 BUG-15 已标未读仍显示「标记未读」
- 根因：`conversation_action_sheet.dart:20-23` 静态菜单项；`showConversationActionSheet` 无未读入参；`markUnread` 恒置 true 无 toggle。
- 方案：sheet 增加 `manualUnread` 入参（matrix_home_page.dart:983 传入），已标未读时显示「取消未读」；新增 `clearManualUnread` mutation（偏好层已有 `copyWith(manualUnread:false)`）。
- 测试：sheet 两态渲染用例 + 取消未读后列表恢复。

### A4 BUG-20 会话列表草稿标识
- 根因：`RoomDraftStore` 仅 room_page 消费；列表副标题链路无草稿。
- 方案：会话列表快照读取草稿（账号+房间键），副标题渲染灰色「草稿：」+ 红色内容前缀（微信式），无草稿回退现逻辑；进入会话清空草稿后列表即时刷新。
- 测试：列表 tile 有草稿/无草稿/草稿清空后三态。

### A5 BUG-22 视频通话接听按钮
- 根因：`call_page.dart:522-532` 接听图标恒 `voiceCallFilled`；图标集无 `videoCallFilled`。
- 方案：`changliao_icons.dart` 增加 `videoCallFilled`（CupertinoIcons.video_camera_solid 或 videocam_fill）；`_incomingControls` 按 `controller.state.type` 分支。
- 测试：视频来电断言视频图标、语音来电断言语音图标。

### A6 BUG-14 通话气泡区分语音/视频 + 点击重拨
- 根因：`wechat_call_bubble.dart:12,17` 有 `video` 字段但 build 未用（恒语音图标）；无 onTap；`message_action.dart:77` 不允许通话消息重拨。
- 方案：①按 `video` 切换图标与文案（「视频通话/语音通话」+ 时长）；②气泡点击直接按原类型回拨（走现有 call adapter 发起入口）；③长按菜单允许「回拨」。
- 测试：气泡两类型渲染 + 点击触发回拨（fake call adapter 记录调用）。

### A7 BUG-32 引用按钮样式
- 根因：`message_action_sheet.dart:22` 用 `CupertinoIcons.reply`（回复箭头）。
- 方案：更换为引用语义图标（双引号/引用角标），与微信「引用」一致；如聊天记录页有独立操作条一并替换。
- 测试：图标断言用例更新。

### A8 BUG-30 补齐：申请页消费 duplicate 响应
- 根因：`request_friend_page.dart:208-220` 忽略服务端 `duplicate: true`，一律报「申请已发送」。
- 方案：`_submit` 读取 `result['duplicate']`，改为「已申请过，请等待对方验证」；服务端 message 不再裸显。
- 测试：duplicate=true 分支用例。

### A9 BUG-16 发起群聊默认选中当前会话对象
- 根因：`onCreateGroup` 是无参 `VoidCallback`（room_page.dart:2678 → app_home.dart:2069），`GroupChatController.selectedMatrixUserIds` 恒空。
- 方案：链路传 peer 的 matrixUserId（可空），`GroupChatController` 构造接受 `preselected` 初始选中；页面可取消勾选。
- 测试：从单聊信息页进入发起群聊，对方默认选中且可取消。

### A10（必做，D1 已拍板）BUG-11 拉黑确认框按钮「取消/确定」
- 现状：确认按钮文案为语义化的「加入」（contacts_page.dart:1090，`_confirm('加入黑名单', …, confirmLabel: '加入')`）。
- 方案：标题与说明文案保留，确认按钮字面改为「确定」；同步修订 `contacts_bug_0917_test.dart:192` 的断言。
- 测试：确认框两按钮断言（取消/确定）。

## 四、批次 B：跨端/服务端修复（预计 4~6 人日）

### B1 BUG-21 互为好友申请，第二个通过报错（服务端，P0）
- 根因：`services/business-api/app/modules/friendship/service.py:53-65` `accept()` 不查重，无条件插入 → `uq_friendship_pair` 唯一约束 IntegrityError → 500；客户端兜底成「操作未完成」。
- 方案：accept 先查 `(user_low_id,user_high_id)` 已存在 → 幂等置 ACCEPTED 返回（不抛错）；客户端对"已是好友"静默成功并刷新列表。注意经 DB 层唯一约束兜底（并发下捕获重复键同样幂等返回）。
- 测试：服务端互为申请场景（先后通过两次都成功）；客户端 409/已存在静默分支。

### B2 BUG-24 补齐：拉封禁用户进群的提示与撤回
- 现状：服务端 `/groups/auto-join` 已分失败桶（`GROUP_INVITEE_UNAVAILABLE`），但客户端 `group_chat_info_controller.dart:265-269` 丢弃 code，统一提示「部分成员需等待确认」，且不撤回已发出的 Matrix invite。
- 方案：`GroupAutoJoinOutcome` 保留 code；`GROUP_INVITEE_UNAVAILABLE` 显示「该账号已被限制，无法加入」并撤回对应 Matrix invite。
- 测试：分桶文案用例 + 撤回调用断言。

### B3 BUG-23 通话结束后未读数虚高
- 根因：通话结束不推进已读回执；`m.call.*` 信令计入服务器未读（`conversation_read_state.dart:64-78` 只做"清零位点相等"抑制）。
- 方案（客户端先行）：通话挂断/拒绝后对通话房间 `setReadMarker` 至最新事件；与客服确认是否需服务端把 `m.call.*` 从 notificationCount 剔除（治本）。
- 测试：挂断后未读数断言（本地投影层）。

### B4 BUG-19 封禁用户登录提示（决策点 D2）
- 根因：服务端把封禁与密码错误合并为 `CREDENTIALS_INVALID`（identity.py:624-634，可能是有意的防枚举设计）；客户端 401 统一显示「账号或密码错误」。
- 方案（待产品确认 D2 后执行）：服务端对 `status != ACTIVE` 返回专用 403 `ACCOUNT_SUSPENDED`（仅对"密码正确"的请求返回，避免枚举）；客户端提示「账号已被限制，请联系客服」。若产品坚持防枚举，则关闭本项并在清单标注"按设计"。

### B5 BUG-29 群主自动转移（决策点 D3）
- 根因：客户端 `leave()`（group_chat_info_controller.dart:500-512 → matrix_e2ee_client.dart:3459）无群主转移；服务端无退群转移端点。
- 方案：客户端 owner 退出且剩余成员 ≥1 时，先 `transferOwnership` 给最早加入的活跃成员再退出（沿用现有手动转让能力，不需要服务端新端点）；matrix-bot 自动化列为备选。
- 测试：owner 退出触发转移 + 非 owner 退出不转移。

### B6 BUG-12 更换邮箱（最大单项，决策点 D4，预计 2~3 人日）
- 根因：注册 session 与邮箱强绑定——客户端「修改邮箱」仅返回注册页，`_sendVerification` 只向旧 session 的旧邮箱重发（registration_page.dart:208-214）；服务端无任何更换邮箱端点（identity.py:372-505）。
- 方案（待交互确认 D4）：客户端「更换邮箱」→ 用新邮箱作废旧 session 并重建（服务端新增 `registrations/{session}/email` 更新端点：校验未验证状态、更新邮箱、重发验证邮件）；旧 session 作废防两邮箱同时可达。
- 测试：服务端更新端点用例（未验证状态/已验证拒绝/重发到新邮箱）；客户端流程用例。

## 五、批次 C：体验增强（P2，预计 4~6 人日，可与 A/B 并行穿插）

| 项 | 根因摘要 | 方案摘要 |
|---|---|---|
| BUG-03 补齐 | 字母条整块垂直居中，未锚定「标签」分区下方 | 索引条 top 锚定 3×contactTileHeight 之下，矮屏向下顺延 |
| BUG-28 | 附缩略图时跳过 generateThumbnail → 事件顶层缺 w/h，两次发送落入不同布局 | 发送路径把解码尺寸写入事件 `info.w/h`；展示层回退 `thumbnail_info` 宽高比 |
| BUG-35 补齐 | 相册视频无百分比进度、无暂停 | 相册视频接 video_send_stage 进度；暂停能力评估（涉及上传中断，单列决策 D5） |
| BUG-38 | 封面四步串行无重试、失败裸显、孤儿 upload | 链路重试 + 友好文案；失败清理/复用 uploadId |
| BUG-39 | 转账详情无推送/轮询，对方收款不刷新（决策点 D6） | 短期：详情页打开期间回前台/定时轻轮询；长期：结算推送订阅 |
| BUG-40 | 语音播完即停（被测试固化） | 连播队列：读完自动播同会话下一条未读语音，提供开关（决策点 D7） |

## 六、流程与门禁

1. 每项独立 TDD（红→绿），不共享测试夹具跨项复用；客户端改动跑 `flutter analyze` + 相关测试，收口跑全量 `flutter test` + `pwsh -NoProfile -File scripts/verify.ps1`；服务端改动跑 `services/business-api` 测试套件。
2. 每批一份任务记录（`docs/workflow/tasks/2026-09-19-defect-batch-<批>.md`），验收台账逐项回填 CSV。
3. 交付：每批完成后出 debug 包（ARM64、`chatflowParallelDebug=true` 并行签名装 MI 6，沿用今天的流程），用户真机验收；正式发布按 `docs/runbooks/android-apk-rebuild.md` 走重建+验证+固定签名身份。
4. CSV 回填纪律：状态、修复提交、验收结果三列随任务记录同步更新，不再出现"代码已修但清单空白"。

## 七、决策点（用户批复状态，2026-09-19）

| # | 决策 | 状态 |
|---|---|---|
| D1 | BUG-11 拉黑确认框：标题/说明文案保留，按钮为**「取消」+「确定」**（确认按钮不用「加入」） | ✅ 已拍板，批次 A10 转必做 |
| D2 | BUG-19 封禁提示：服务端返回专用 403（**仅在密码正确时**），客户端提示「账号已被限制」 | ✅ 已拍板 |
| D3 | BUG-29 群主转移对象：**最早加入的成员** | ✅ 已拍板 |
| D4 | BUG-12 换邮箱交互边界：**已拍板=验证前可改（作废旧会话、验证码发新邮箱）；验证后走账号设置换绑** | ✅ 已拍板 |
| D5 | BUG-35：**已拍板=不做暂停**，验收口径改为"转码中/上传中百分比进度条 + 失败重试" | ✅ 已拍板 |
| D6 | BUG-39：**已拍板=一期轮询**（详情页打开期间每隔数秒轻量查询 + 回前台立即刷新，不动服务端）；二期推送另立 | ✅ 已拍板 |
| D7 | BUG-40 语音连播：提供设置开关，**默认开启**（同会话内连续未读语音连播） | ✅ 已拍板（默认开，修正原建议的默认关） |

## 八、风险

- BUG-34 依赖系统语音识别：无 STT 设备上"转文字"仍会降级为发语音，真机验收需在支持设备上进行。
- BUG-08 后续新增页面若直接用 `CupertinoPageRoute` 会绕过"减少动效"（长review 项，记录在案）。
- BUG-21/19/24/29 涉及服务端，需与 `services/business-api` 现有测试与部署窗口协调；不跑破坏性迁移。
- 并行会话仍在同仓库工作：执行前按文件所有权划界（本计划各项文件清单即所有权声明），避免同文件并发编辑。
