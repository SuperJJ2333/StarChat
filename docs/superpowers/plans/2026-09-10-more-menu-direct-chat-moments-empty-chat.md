# 更多菜单 / 直聊失败与重复会话 / 朋友圈分页 / Empty chat 修复计划

**日期：** 2026-09-10
**状态：** 已批准（用户 2026-09-10 任务单授权：范围=代码修改、测试与验证记录；不部署、不动真实用户数据、不打包 APK）
**依据规格：** `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`（§3.1 信任边界、§7 Matrix 通信域）、`docs/superpowers/specs/2026-08-21-contacts-friend-and-conversation-operations-design.md`（§4 会话操作语义）、`CONTEXT.md` 词汇表

## 0. 调查结论（根因）

### 0.1 “更多”菜单过宽（问题二，已证实）
- 消息页导航栏右上角 `messages-more` 按钮触发 `matrix_home_page.dart` `_showMore()`，弹 `CupertinoActionSheet`。
- Flutter SDK（`cupertino/dialog.dart`）强制 `SizedBox(width: 屏宽 − 16)`：菜单恒为全宽，与内容无关；选项行（图标+文字）虽已居中，但整张菜单远宽于内容，形成大面积左右空白（用户感知为“右侧空白过宽”）。
- HTML demo（`frontend/src/styles/components.css` `.c-action-sheet`）同样是全宽 `left:0;right:0`。

### 0.2 好友“发消息”失败与重复会话（问题三）
已证实（代码路径）：
- 错误文案“无法打开加密会话”是 `app_home.dart` 两处 `_openMessage`（主状态 `:1116`、通讯录 Tab `:1546`）的**兜底 catch-all**：同步超时（`TimeoutException`）、好友映射缺失（`StateError('The contact is no longer a current friend')`）、规范房间校验失败（`_forPeer`/`_requireSafe`）、网络错误全部渲染成同一文案，且无重试入口。
- 重复会话创建路径一（本地同步滞后）：`CanonicalDirectChatGateway` 打开规范房间失败时，仅 `TimeoutException` 阻止新建；`MatrixDirectChatBackend.openCanonicalRoom` 里成员/加密状态**尚未同步送达**时 `_requireSafe` 抛 `StateError`（非 Timeout），网关回落 `_inner.openOrCreateDirectChat` 新建第二个房间，`registerRoom` 随即把规范目录改指新房间，旧房间永久残留为列表重复项。
- 重复会话创建路径二：`openCanonicalRoom` 对“对方已退出”的规范房间不做 `repairDirectRoom`（重邀）修复，直接校验失败→新建，绕开了 m.direct 路径已有的“先修复保留历史”语义。
- 同一客户端并发/连点已被 `DirectChatController._openings`（按 matrixUserId 复用 in-flight Future）去重；跨设备竞态（对方建房邀请未同步时本端也建房）服务端无原子保证，`register_direct_conversation` 以“最后注册者胜”收敛目录，但不消除两个真实房间。
未验证假设：真机上“这个小鸿”的具体失败类别（同步滞后 vs 修复失败 vs 映射缺失）需客户端日志；无设备/账号口令，本次以代码级结论+本地测试覆盖，记录于验证文档。

### 0.3 朋友圈加载（问题四，已证实）
- 后端 `GET /moments/feed` 已是真正分页：`mode/cursor/limit(1..50,默认20)`，游标=`created_at+id` 双字段稳定排序（base64）。客户端 `momentsFeed(mode:'latest')` 也只取第一页。
- 差距在客户端交互：加载下一页是**手动按钮**（`moments-load-more`），无滚动接近底部自动加载、无下拉刷新、无“没有更多/失败重试”页脚状态；首屏缓存首绘快照只含第一页。
- 后端 `feed()` 在 `latest` 模式按可见性逐行过滤到 `limit+1` 为止（有上限）；`dto()` 存在每条动态的 like/comment 查询（N+1），属于现有每页成本，不在本次范围。

### 0.4 “Empty chat”残留会话（问题五）
已证实：
- 字符串来自内置 Matrix SDK `getLocalizedDisplayname()` 兜底 `i18n.emptyChat`（`third_party/matrix/.../room.dart:280`）：房间无 `m.room.name`、无 canonical alias、且 hero 列表为空。对私聊，**对方退出后服务端 summary 的 `m.heroes` 变为空列表**（SDK `summary.mHeroes ?? [directChatMatrixID]` 对空列表不回退），即渲染“Empty chat”。
- 会话列表 tile 标题 `_conversationTitle`（私聊走备注>昵称>用户名>成员名>localpart 链）不会产生“Empty chat”；但聊天页标题（推送进入 `app_home.dart:1319`）、头像回退（`matrix_conversation_avatar.dart:63`）、全局搜索（`global_search_page.dart:54`）直接用 `getLocalizedDisplayname()`，会露出英文“Empty chat”。
- 产品语义（规格§4 + `interaction_permission.dart`）：删除好友仅删除 Friendship/ContactProfile 行（`friendship/service.py delete_friend`），不退出 Matrix 房间、不清 `m.direct`/规范目录；“删除该聊天”=显式 leave+forget；“不显示该聊天”=本地 hidden 标记（新入站消息会按规则恢复显示）。**删除好友后保留会话是设计行为**（保留聊天记录）。“Empty chat” 房间的直接成因是**对方侧退出**（对端删除会话=leave）后本端名称回退缺失，而非删除好友本身。
- 决策确认项（不在本次擅改）：删除好友后是否自动隐藏会话——建议维持“保留会话、禁止互动”现状（见验证文档 §决策）。

## 1. 修改方案（最小必要）

### A. 更多菜单内容适配宽度（问题二）
- 新增 `apps/mobile_flutter/lib/ui/components/wechat_more_sheet.dart`：`showWeChatMoreSheet<T>` 底部弹层。
  - 宽度=各选项“图标20+间距10+文字宽”取最大 + 对称水平 padding（各 24）；钳制在 `[200, 屏宽−32]`（边缘安全间距 16×2）；水平居中。
  - 选项行 icon+text 作为整体居中；最小触控高 48；取消按钮同宽独立分区；颜色/圆角/分割线沿用 CupertinoActionSheet 视觉与暗色动态色。
  - 大字体：文字宽度按 `MediaQuery.textScalerOf` 实测，超上限自动加宽至屏宽上限，不溢出（必要时换行不截断）。
- `matrix_home_page.dart _showMore` 改用该组件，保留 `messages-appearance` 等 key 与全部行为。
- HTML demo 同步：`components.css` 增加 `.c-action-sheet--fit`（fit-content/min-width/max-width/居中），`messaging.js` 该弹层加变体类；不改注册表契约（无新组件）。
- 测试：新 widget 测试（宽度适配、水平居中、大字体无溢出、点击回传、取消）；既有 `matrix_home_scan_entry_test` 保持通过。

### B. 直聊：规范房间先修复/等待再新建 + 错误分级可重试（问题三）
- `matrix_direct_chat_adapter.dart openCanonicalRoom`：快照不安全时（a）有界重 poll（3×300ms，等待成员/加密状态同步）；（b）仍不安全走 `repairDirectRoom`（重邀对方/补加密，保留历史）；（c）修复失败才抛 `StateError` 走既有“新建并注册”回落。`TimeoutException` 语义不变（禁止借超时新建）。
- 新增 `direct_chat_failure.dart`：`DirectChatFailureKind{syncPending,contactUnavailable,networkOrOther}` + `describeDirectChatFailure(Object)` 纯函数（不含敏感信息）。
- `app_home.dart` 两处 `_openMessage`：错误弹窗按类别给文案（“会话同步中，请稍后重试”/“该好友已不在好友列表”/“网络异常，请检查网络后重试”），非映射缺失类提供“重试”按钮（复用同一打开流程）；同一弹窗仍不含房间号等诊断细节，诊断保留在既有 `developer.log`（DirectChat 结构化日志）。
- 测试：`canonical_join_sync_test` 增加“成员未同步→等待收敛→复用不新建”、“对方已退出→重邀修复→复用”；`direct_chat_sync_failure_test` 保持语义；错误分级纯函数红绿测试；弹窗重试 widget 测试。

### C. 朋友圈滚动增量加载（问题四）
- `moments_page.dart`：
  - `ListView`→`CustomScrollView`：`CupertinoSliverRefreshControl` 下拉刷新（重新拉第一页、epoch++、成功后更新缓存与游标；失败保留已展示内容并顶部提示）。
  - 滚动监听 `extentAfter<600` 自动 `_loadMorePosts`（复用现有 epoch/identical 并发去重；失败页脚显示“加载失败，点击重试”，保留内容）。
  - 页脚三态：加载中 spinner / 没有更多了 / 失败重试；空列表显示空态；首屏仍走缓存首绘+后台刷新（不变）。
  - 合并去重保持服务端顺序（沿用 id 去重、插入序稳定）。
- 接口不改（沿用现契约），OpenAPI/生成客户端无需变更。
- 测试：`moments_flow_test` 改造+新增（首屏仅一页请求、滚动触发下一页且并发只发一次、到底停止、失败保留内容可重试、刷新重置分页与“刷新 vs 加载更多”竞态、空态）。

### D. Empty chat 名称回退（问题五）
- 新增 `features/matrix/matrix_room_display_name.dart`：`roomDisplayName(Room)`——私聊永远不返回“Empty chat”：房名→对方成员 displayname→对方 m.direct ID localpart；群聊维持 SDK 行为。
- 替换私聊可达的裸调用点：`matrix_conversation_avatar.dart:63`、`app_home.dart:1319`、`global_search_page.dart:54`、`matrix_home_page.dart:1021`。
- 不删房间、不隐藏历史（防误伤，不用“名称过滤”规则）；visibility 规则不变（hidden 恢复逻辑已合规）。
- 测试：新增纯逻辑/伪 Client 测试（房名、对方在、对方已退 heroes 空、成员事件被剪枝、群聊不受影响）。

## 2. 拥有文件清单
- 改：`apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`、`matrix_direct_chat_adapter.dart`、`app_home.dart`、`moments_page.dart`（features/moments）、`matrix_conversation_avatar.dart`、`global_search_page.dart`
- 新：`lib/ui/components/wechat_more_sheet.dart`、`lib/features/matrix/direct_chat_failure.dart`、`lib/features/matrix/matrix_room_display_name.dart`
- demo：`frontend/src/styles/components.css`、`frontend/src/screens/messaging.js`
- 测试：`test/features/matrix/{canonical_join_sync_test,direct_chat_sync_failure_test}.dart` 扩展；新 `test/features/matrix/matrix_room_display_name_test.dart`、`test/ui/components/wechat_more_sheet_test.dart`、`test/features/moments/moments_flow_test.dart` 扩展
- 记录：`docs/verification/2026-09-10/`（红绿证据、复现步骤、决策确认项）

## 3. 验证与评审
- `flutter test`（相关套件）+ `pwsh -NoProfile -File scripts/verify.ps1`（含 UI 契约、OpenAPI drift）。
- 先规格符合性（Matrix/业务域边界、E2EE 不变、无资金路径、命名词汇表），后质量/安全（错误信息不泄露、无敏感日志、无占位符）。
- 不部署、不打包、不清生产数据；历史重复房间的兼容规则（复用规范房间、旧房间保留可访问、用户可手动“删除该聊天/不显示”）写入验证文档供确认。

## 4. 2026-09-10 用户授权的复核与纠正

用户要求检查上述修改、发现错误自行纠正，重点确保好友发消息与重复会话链路。
本次领取范围：直聊网关、Matrix 适配器及 app_home 接线；朋友圈分页异常与刷新竞态；对应测试和验证文档。其他并行工作文件不修改。

- 已由失败测试证实：目录查询失败、规范房间状态失败、重邀失败仍会触发替代房间；纠正为保留原房间重试，不能把异常当作不存在。
- SDK requestParticipants 可直接返回完整但过期的本地缓存；不健康房间及重邀后须读取服务端成员，不以重复读缓存判断修复失败。
- 规范房间打开必须传入所点击好友的 Matrix ID；m.direct 是可缺失/过期的元数据，不可作为该次操作的好友身份权威。
- 验证朋友圈旧请求失败不污染新世代、首屏失败后的滚动不会抛未处理异常。保留原有分页和显示规则。
- 不修改 E2EE 算法、密钥与认证机制。全程保留加密及双人检查，不清理真实历史房间。
- 跨设备同时首次创建的原子仲裁不在原客户端修复保证范围；服务端当前覆盖式注册和历史重复房间必须如实列为剩余限制，不能声称已根除。
