# 更多菜单 / 直聊失败与重复会话 / 朋友圈分页 / Empty chat 验证记录

> 后续复核已发现并纠正本记录对应实现中的遗漏，尤其是缓存成员复验和异常回落新建路径。最终结果及保证范围请见 [复核纠正记录](2026-09-10-direct-chat-review-corrections.md)。本页作为原轮次记录保留，不应再据此认定重复会话已根除。

日期：2026-09-10
计划：`docs/superpowers/plans/2026-09-10-more-menu-direct-chat-moments-empty-chat.md`（用户当日任务单授权；范围=代码修改、测试与验证记录，未部署、未操作真实用户数据、未打包 APK）
产物目录：`docs/verification/artifacts/2026-09-10/ui-fixes/`

## 一、根因结论（已证实 / 未验证假设）

### 问题二：导航栏右上角“更多”菜单过宽（已证实）
- 消息页导航栏 `messages-more` 按钮触发 `matrix_home_page.dart _showMore()`，弹出 `CupertinoActionSheet`。
- Flutter SDK（`packages/flutter/lib/src/cupertino/dialog.dart`）在竖屏下强制 `SizedBox(width: MediaQuery.widthOf − 2×8px)`，菜单恒为全宽，与内容无关；选项行（图标+文字）虽居中，但整张菜单远宽于内容，形成大面积两侧空白（用户感知“右侧空白过宽”）。HTML demo（`.c-action-sheet` `left:0;right:0`）同样全宽。

### 问题三：好友“发消息”报“无法打开加密会话”+ 重复会话
已证实（代码路径与本地测试复现）：
1. 错误文案是 `app_home.dart` 两处 `_openMessage` 的兜底 catch-all：同步超时（`TimeoutException`）、好友映射缺失（`StateError('The contact is no longer a current friend')`）、规范房间校验失败、网络错误全部渲染成同一标题/文案，且无重试入口。
2. 重复会话成因（本地状态滞后）：规范房间打开路径 `MatrixDirectChatBackend.openCanonicalRoom` 在本地成员/加密状态尚未同步送达时校验失败抛 `StateError`（非 Timeout），`CanonicalDirectChatGateway` 随即回落 `_inner.openOrCreateDirectChat` 新建第二个私聊；`register_direct_conversation`（服务端“最后注册者胜”）把规范目录改指新房间，旧房间永久残留为列表重复项。**已由新增测试证明该路径存在并在修复后收敛。**
3. 重复会话成因（对端已退出）：canonical 路径不做 `repairDirectRoom`（重邀），直接失败→新建，绕开 m.direct 路径既有的“先修复保留历史”语义；且对方退出后 participants 查不到对方 ID，重邀目标需从 `directChatMatrixID` 推导。**已由新增测试证明。**
4. 同一客户端并发/连点已被 `DirectChatController._openings` 按 matrixUserId 复用 in-flight Future 去重（既有测试覆盖，保持通过）。
未验证假设（缺少访问条件，见“复现限制”）：
- 真机上“测试账号→superJJ→这个小鸿→发消息”当次失败的确切类别（同步滞后 / 修复失败 / 映射缺失）。修复覆盖了以上全部类别的可恢复分支；具体设备可用 `developer.log` 的 `DirectChatCreate`/失败堆栈进一步定位。
- 跨设备竞态的实际边界：服务端 `register_direct_conversation` 无“每对用户一个 Matrix 房间”的原子约束（只有目录行 UNIQUE），无法阻止两个真实房间在两端同时创建；本修复保证的是**同客户端不重复创建 + 打开时按 canonical→m.direct 稳定复用 + 旧房间保留可访问**。跨设备竞态仍可能产生第二个真实房间（双方目录最终收敛到同一房间），需产品层决定是否引入服务端收敛任务。

### 问题四：朋友圈“进入加载全部”（已证实）
- 后端 `GET /api/v1/moments/feed` 已是真分页：`mode/cursor/limit(1..50, 默认20)`，游标为 `created_at+id` 稳定双字段（base64）；客户端也只请求第一页。
- 差距在交互：下一页是**手动按钮**（`moments-load-more`），无滚动接近底部自动加载、无下拉刷新、无“没有更多/失败重试”状态；本次为纯客户端交互修复，接口契约未变。
- 附带核实：`dto()` 每条动态有 like/comment 查询（N+1），属于既有每页成本（上限 limit），未在本次范围内改写。

### 问题五：消息页残留 “Empty chat”（已证实）
- 字符串来自内置 Matrix SDK `room.getLocalizedDisplayname()` 兜底 `i18n.emptyChat`（`third_party/matrix/lib/src/room.dart:280`，`matrix_default_localizations.dart:108`）。触发条件：房间无 `m.room.name`、无 canonical alias、hero 列表为空。**对方删除会话（=leave+forget，规格 §4）或退出后，服务端 summary 的 `m.heroes` 变为空列表**，且 SDK 对“空列表”不回退到 m.direct 映射，于是渲染英文 “Empty chat”（聊天页标题、头像回退、全局搜索等界面）。新增测试先复现了 SDK 的 “Empty chat” 基线。
- 产品语义（`2026-08-21-contacts-friend-and-conversation-operations-design.md` §4 + `interaction_permission.dart` + `friendship/service.py delete_friend`）：删除好友仅删除 Friendship/ContactProfile，不退出 Matrix 房间、不清 m.direct/规范目录；**删除好友后保留会话是设计行为（保留聊天记录）**。“Empty chat” 的直接成因是**对端退出**，不是删除好友本身。
- 消息列表 tile 标题（`_conversationTitle`：备注>昵称>用户名>成员名>localpart）本就不会产生 “Empty chat”，因此未对列表做任何“按名称过滤/隐藏”的误伤性规则。

## 二、修改内容与关键取舍

| 文件 | 修改 |
| --- | --- |
| `lib/ui/components/wechat_more_sheet.dart`（新） | 内容适配宽度底部菜单：按“最宽选项文字+图标20+间距10+对称 padding”实测宽度，钳制 `[200, 屏宽−32]`，水平居中、贴底；取消按钮同宽独立分区；圆角/分割线/按压色/暗色沿用 CupertinoActionSheet 视觉。取舍：不直接约束 `CupertinoActionSheet`（SDK 硬编码全宽，无法收敛），自绘容器保留原交互（点击先收起再执行、取消）。弹层在根 overlay，字体缩放从调用方 context 显式带入 |
| `lib/features/matrix/matrix_home_page.dart` | `_showMore` 改用 `showWeChatMoreSheet`，删除冗余 `_action`；保留 `扫一扫` 跳转、`外观` 主题选择等全部行为 |
| `frontend/src/screens/messaging.js`、`components/feedback.js`、`catalog/contracts.js`、`styles/components.css` | demo 同步：`app-action-sheet` 支持 `variant="fit"`（`.c-action-sheet--fit`：fit-content/min 200px/max 屏宽−32/水平居中），消息页“新建会话”弹层使用该变体；注册表 attributes 增加 `variant` |
| `lib/features/matrix/matrix_direct_chat_adapter.dart` | `openCanonicalRoom`：目标 ID 优先取 `directChatMatrixID`（对方退出时 participants 查不到）；新增 `_ensureHealthy`：快照不健康时有界轮询（4×300ms）等待同步收敛 → 仍不健康走 `repairDirectRoom`（重邀对方/补加密，保留历史）→ 不可修复才抛 `StateError` 交由上层按既有语义回落新建。取舍：`TimeoutException` 语义不变（禁止借超时新建，防止重复房间）；等待上限 ~2s 换取消除“同步滞后→重复建房” |
| `lib/features/matrix/direct_chat_failure.dart`（新） | 失败分级 `syncPending/contactUnavailable/networkOrOther` + 文案 + `showDirectChatFailureDialog`（保留原标题“无法打开加密会话”，按类别给真实状态；除好友映射缺失外提供“重试”） |
| `lib/app_home.dart` | 两处 `_openMessage` 兜底 catch 改用统一失败弹窗（重试回调重跑同一打开流程）；推送进入的聊天页标题改用 `roomDisplayName` |
| `lib/features/moments/moments_page.dart` | `ListView`→`CustomScrollView`：`CupertinoSliverRefreshControl` 下拉刷新（重新拉第一页、epoch++ 使旧游标响应失效、成功更新缓存，失败保留内容并顶部提示）；滚动监听 `extentAfter<600` 自动加载下一页，护栏在任何 await 之前同步置位（同一手势多个滚动事件不重复请求）；页脚三态（加载中/“加载失败，点击重试”/“没有更多了”）+ 空列表空态；缓存首绘+后台刷新保留，后台刷新受 epoch 保护。取舍：失败后须手动点重试（避免滚动反复撞失败接口） |
| `lib/features/matrix/matrix_room_display_name.dart`（新） | `roomDisplayName(room)`：房名→对方成员 displayname→m.direct 对方 localpart，私聊永不返回 “Empty chat”；群聊沿用 SDK。接入 `matrix_conversation_avatar.dart`、`global_search_page.dart`、`app_home.dart` 推送开聊天路径 |

不变式：不删房间、不隐藏历史、不用名称/最后消息过滤会话；E2EE 校验只加强不放松（`_isHealthy` 仍要求 encrypted+双人）；不改业务 API 契约（无 OpenAPI/生成客户端变更）；错误文案不含房间号/Matrix ID/网络细节。

## 三、测试命令与结果

红→绿（红态为本次会话中实际执行的失败输出，绿态产物已存档）：

- 问题二红：`flutter test test/ui/components/wechat_more_sheet_test.dart` → 组件不存在编译失败；接入前旧实现不满足宽度断言（`Expected: a value less than <358.0>`/全宽）。绿：`00:00 +7: All tests passed!`（含宽度适配、水平居中、图标+文字整体居中、大字体 2.0、超长选项钳制 358、窄屏 320、取消/动作回调）。见 `focused-green.log`。
- 问题三红：`canonical_room_readiness_test` 三用例在旧实现下失败（`invites=['']`——目标 ID 推导为空证明重邀缺失；StateError 直抛）。`direct_chat_failure_test` 在模块不存在时编译失败。绿：8/8 通过（成员滞后收敛复用不新建、对方退出重邀复用、重邀失败回落新建、失败分级、重试弹窗、好友已删不提供重试）。既有 `direct_chat_controller_test`/`canonical_direct_chat_test`/`canonical_join_sync_test`/`direct_chat_sync_failure_test` 全部保持通过（含“同步超时不得新建”回归）。
- 问题四红：`moments_pagination_test` 5 用例在旧实现下全失败（无自动加载/无重试页脚/无刷新/无空态）。绿：5/5 通过（首屏仅一页请求；滚动触发下一页且并发只发一次；到底停止且不再请求；失败保留内容+重试成功；下拉刷新重取第一页并重置游标；旧游标响应迟到被丢弃；空态）。`moments_flow_test` 原按钮流程改造为自动加载后通过。整个 moments 目录 37/37 通过。
- 问题五红：`matrix_room_display_name_test` 在模块不存在时编译失败；基线断言 `expect(room.getLocalizedDisplayname(), 'Empty chat')` 证明 SDK 现状。绿：5/5 通过（房名、heroes 空回退成员名、成员事件缺失回退 localpart、heroes 正常、群聊沿用 SDK）。
- 全量：`flutter analyze` → `No issues found!`；`flutter test`（全仓库）→ **1429 个测试全部通过**（`full-flutter-test.log`）。
- HTML demo：`node --test` → 129 通过 / 0 失败；`py -3.12 scripts/verify_ui_contract.py` → `UI contract drift: PASS (17 components, 330 screens)`。
- 仓库门禁：`pwsh -NoProfile -File scripts/verify.ps1` → 首轮在 `tests/mobile/test_figma_ui_contract.py` 抓到真实回归：替换菜单时丢掉了契约固定的 `key: const Key('messages-appearance')`（1 failed, 66 passed）。修复：`WeChatMoreSheetItem` 增加 `key` 字段并落到按钮上，`外观` 项恢复该定位键；复跑 `py -3.12 -m pytest tests/mobile -q` → **67 passed**，随后整链复跑 `verify.ps1` → **Verification: PASS**（仓库策略/部署策略/模板/渲染冒烟/infra/getui bridge/matrix bot/business API+worker/Flutter boundary 67/UI 契约 drift/Business API import/AST/Alembic migrations/OpenAPI drift/Docker Compose render 全部通过）。

### 复现限制（如实记录）
- 未在真机/真实账号复现“无法打开加密会话”：生产 API（liuhetong888.com）需用户账号口令，任务范围禁止操作真实用户数据；本次以代码路径分析 + 本地单元/组件测试复现全部失败分支。设备复核步骤见下节。

## 四、手工验收步骤

问题二：
1. 打开 APP → 消息页 → 点右上角“…”：菜单宽度应明显窄于屏幕、水平居中，选项“图标+文字”整体居中，两侧留白对称；底部“取消”同宽。
2. 系统设置调大字体（或开发者选项字体缩放 1.5–2.0）重复步骤 1：菜单加宽但不出屏、不截断；极端长文案时换行不溢出。
3. 依次点“发起群聊/添加朋友/扫一扫/外观”：各自正常进入；再次打开点“取消”仅收起。

问题三：
1. 好友页（如“这个小鸿”）→“发消息”：正常应直进聊天页；列表已有该好友私聊时不新建房间（消息页不新增重复会话）。
2. 弱网/首次登录同步未完成时点“发消息”：提示“对方会话还在同步中，请稍后重试”，弹窗点“重试”可重新打开；期间消息页不得出现第二个相同会话。
3. 删除该好友后再点历史会话进入：提示“该好友已不在你的好友列表。”且无“重试”按钮。
4. 断网点“发消息”：提示网络异常，恢复网络后点“重试”成功。
5. 若历史上已存在两个相同会话：发消息始终进入规范房间；旧房间仍可从列表打开查看历史，可长按“删除该聊天/不显示该聊天”自行处置。

问题四：
1. 进入朋友圈：首屏仅展示最新一页（后台请求 `/moments/feed` 仅一次，无 cursor）。
2. 快速滚动接近底部：自动加载下一页；连续滚动不会发出重复请求（抓包/日志仅一次/页）。
3. 翻到最后一页：显示“没有更多了”，继续滚动无请求。
4. 顶部下拉：刷新最新一页，游标重置（刷新后再滚动会拉取新内容的第二页）；刷新失败保留原内容并提示。
5. 断网滚动加载：页脚“加载失败，点击重试”，已展示内容保留；恢复网络点重试成功。
6. 无动态账号：显示“还没有朋友圈动态”空态。

问题五：
1. 对方账号删除该会话（leave）后，本端消息列表该会话仍在（保留历史），打开聊天页标题/会话头像回退显示对方名称（如“这个小鸿”），不再出现 “Empty chat”。
2. 删除好友：会话保留（设计行为，规格确认项见下）；进入该会话互动受权限门限制。
3. 长按“不显示该聊天”：会话消失；重启/重新同步后不再出现（仅当对方新消息进来时按既有规则恢复）。
4. 长按“删除该聊天”：leave+forget 后会话消失且重启不再出现。

## 五、决策确认项（需产品/用户确认，本次未擅自执行）

1. **历史重复房间**：修复后不再新增重复，但历史遗留的重复真实房间仍会并排显示（保留历史消息访问能力，未删除/未隐藏掩盖）。处置选项：a) 维持现状由用户手动“删除该聊天”；b) 服务端增加收敛任务（把 DirectConversation 指向保留房间并引导客户端 leave 其余）——需 ADR（涉及 E2EE 房间生命周期）。建议 a。
2. **删除好友后的会话可见性**：现设计=保留会话+禁止互动（保留聊天记录）。若产品希望“删除好友即隐藏会话”，应基于 hidden 偏好实现（可逆、可同步、不删数据），需单独批准。
3. **跨设备竞态**：如需绝对杜绝双房间，需要服务端在创建/注册时做“每对用户唯一活跃房间”的仲裁（涉及 Matrix 域与业务域边界，需 ADR）。
4. `frontend/artifacts/screenshots/` 存在 2 张历史遗留本地截图（332 vs 330 屏），导致 `frontend verify` 的截图步骤在本工作区失败；与本次改动无关（本次未增删屏幕），建议另行清理后重跑 `node scripts/screenshots.mjs`（需 Chrome）。

## 六、评审记录

规格符合性：仅客户端交互/恢复路径变化；通信域仍由 Matrix 承载、业务身份映射不变；E2EE 前置校验（encrypted+双人）未放松，重邀修复沿用既有 m.direct 路径语义；资金域零接触；无名称/词汇表漂移（verify_ui_contract PASS）。
质量与安全：错误弹窗不含敏感细节，诊断仍走 `developer.log` 结构化日志（不含消息内容）；无占位符/临时绕过/被忽略的告警（analyze 0 issues）；并发护栏同步化并加竞态测试；验证产物均在本目录。
