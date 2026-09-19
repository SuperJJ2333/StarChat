# ChatFlow 全局页面状态管理审计 — 非 Offline First 页面清单（2026-09-19）

**目标：** 找出 `features/` 下所有不符合"微信级数据加载模型"的页面，并给出最小改动。

**模型（四条，全部满足才算 Offline First）：**
- **L1 本地优先**：发网络请求前，先从本地缓存/持久化存储（SQLite、SharedPreferences、会话级共享 Store）读取可展示的数据。
- **L2 立即展示**：首帧就渲染 L1 拿到的数据；不得在请求飞行期间把已有内容替换成整页 spinner/空态。真的没有数据时用骨架/占位可以，把已知数据藏在 spinner 后面不行。
- **L3 后台同步**：网络刷新在渲染之后进行，且不把整页锁成 `busy` 阻塞交互。
- **L4 失败不覆盖**：刷新失败时已展示的数据必须留在屏幕上，不清空、不变错误页/红条；只有"从未成功且无任何数据"才允许报错。

**方法：** 7 个只读审计 agent 分头逐文件读码，逐条给 `file:line` 证据；本人复核了其中的关键判定（`ledger_controller.dart`、`chat_search_page.dart:335-365`、`contact_tag_pages.dart:84-91`）。**路由归属例外**：`ui/chat/chat_search_page.dart` 位于 `ui/` 而非 `features/`，但它是"查找聊天记录/分类/群成员"的真实页面，故一并列出。

---

## 1. 非 Offline First 页面（必须改）

| 页面 | 位置 | 失败项 | 关键证据 | 最小改动 |
|---|---|---|---|---|
| **钱包「全部账单」/交易记录** | `features/ledger/ledger_controller.dart:38-43` | L1 L2 L4 | `load(refresh:true)` **先 `_items.clear()` 再请求**；失败仅设 `error='账单加载失败，请重试'`（`:86-92`）；无任何本地缓存，进程内也不保留上次结果 | 首次加载后才清空；失败保留 `_items`；把上一页快照落到本地（按账号/筛选键），进入时先渲染 |
| **查找聊天记录** | `ui/chat/chat_search_page.dart:335-355` | L1 L2 L4 | 有 `_lastPage`（`:358`）却先判 loading → 整页 spinner（`:335-337`）、failed → 整页"查询失败"（`:338-355`），`_lastPage` 分支不可达；查询源在本地命中不足时会 await 网络翻页（`room_page.dart:2844-2869`） | 先渲染 `_lastPage`（非空时），loading/failed 降级为内联头/尾（复用 `:415-435` 分页尾） |
| **新的朋友** | `features/contacts/contacts_page.dart:1641` | L1 L2 L4 | `requests` 仅网络（`:1683`），pending 与失败都渲染"暂无新的朋友"（`:1844`、`:1855-1859`） | 按账号持久化上一次 `/friends/requests` 结果并先渲染；失败保留行 |
| **通讯录标签**（3 个页面） | `features/contacts/contact_tag_pages.dart:10 / :142 / :302`；`contacts_page.dart:1225` | L1 L2 L4 | `tags = api.contactTags()`（`:18,:21-25`）无缓存；`!snapshot.hasData` 即整页 spinner（`:87-89`，同时是错误态）；成员页直接 `api.listContacts()`（`:152`） | 注入 `ProfileRepository` 用 `identityCache.contacts`（`profile_repository.dart:428`）先渲染；标签加一个持久化列表 |
| **邀请码 / 邀请历史** | `features/profile/invite_code_page.dart:21`、`profile_page.dart:606` | L1 L2 L4 | 控制器无 store（`app_home.dart:2648-2649`）；首帧整页 spinner（`:145-147`）；失败把已显示的邀请码换成错误页（`:148-163`，`invite_controller.dart:123-140`） | `InviteCodeController.load` 持久化快照；body 以 `state.invite != null` 为准而非 `status` |
| **入群确认页** | `features/contacts/group_join_confirm_page.dart:10` | L1 L2 | `_info` 只由网络 `_load()`（`:38,:41-60`）产生，`_loading` 整页 gate（`:126-132`） | 按 token 持久化群信息，去掉 `_loading` gate（L4 已合规） |
| **红包领取明细**（财务卡片点进去） | `features/redpacket/red_packet_claim_detail_page.dart:214-215` | L1 L2 | 每页新建 `RedPacketController`（`red_packet_controller.dart:34-48`），无共享缓存，首帧整页 spinner | 复用会话级共享 store + 本地快照 |
| **朋友圈设置 / 排除名单 / 可见范围名单 / 发动态草稿** | `features/moments/moments_settings_page.dart:25`（`:94-98` 整页 gate）、`:171`、`moment_visibility_people_page.dart:34`、`moment_composer_page.dart:58` | L1（设置页另含 L3） | 均先 `await` 网络才渲染；已有 `CacheRepository`/`MomentsPageStore`/`preferencesSnapshot`（`cache_repository.dart:96,154`）没被用上 | 用已存在的 cache 先渲染：`preferencesSnapshot`、`ProfileRepository.contacts`；草稿落本地 |
| **加好友搜索** | `features/contacts/contacts_page.dart:1421` | L1 L4 | 失败时 `items = []`（`:1514-1525`）清空上次结果 | 失败保留上次结果（L2/L3 已合规） |

## 2. 部分符合（Partial）

| 页面 | 位置 | 失败项 | 证据 | 最小改动 |
|---|---|---|---|---|
| 通讯录（首页） | `contacts_page.dart:66` | L1（申请角标）L4（reload） | 角标只来自网络轮询（`app_home.dart:959-1003`）；`reload()`（`:200-206`）替换 future，builder 无 error 分支（`:328-330`）→ 失败变空列表 | 持久化待处理申请数；reload 失败回退 `identityCache?.contacts` |
| 联系人更多页 | `contacts_page.dart:879` | L1 | `blocked` 初始 null，只由网络 `_loadBlockState()` 设置（`:903,:911,:917`）；内存投影只在 catch 里读（`:926-929`） | initState 先读 `blockedContacts` 投影 |
| 扫一扫 → 我的二维码 | `scan_qr_page.dart:27` | L1 | `_openMyQr()` 直接 `ProfileGateway.loadProfile()`（`:222-228`）并禁用两个按钮（`:216-219`） | 传入 identityCache，先渲染本地资料 |
| 钱包充值/提现页 | `wallet/manual_wallet_page.dart` | L2 L3 | 首帧 `—`（`:1353`）因为 `_applyEntryState()` 要等 `await walletIntentScope()`（`:175-181`）；整页 `busy` gate（`:452-461`）也覆盖后台刷新路径（`:365`、`:449`） | 组合根注入 scope/Store 让首帧就有缓存；后台刷新不设 busy |
| 点钻（彩币）页 | `caibi_page.dart:39,64-71` | L2 | Store 在 `await walletIntentScope()` 之后才挂上，首帧 `--`（`:100`）与"暂无点钻流水"（`:234-241`） | 同上 |
| 全局搜索 | `search/global_search_page.dart:46` | L1 L2（仅当 `identityCache == null`） | `_loadContactSummaries` 回退网络 `api.listContacts()`（`:140-143`）并在 `loadRooms()` 之前 await（`global_search_controller.dart:111-120`），本地结果被网络拖住 | 去掉网络回退、先发布本地结果 |
| 联系人资料页 / 资料页 / 催一下 | `profile/profile_page.dart:340 / :526` | L4 | 后台刷新失败后仍把 `state.message` 画成红字（`:514-518`、`:588-595`），数据其实还在 | 删掉这两处红字（保存失败已有 toast，`:401-411`） |
| 通话权限清单 | `settings/notification/call_permission_checklist.dart:20` | L4 | `_refresh` 整体替换 `_state`（`:52-55`），重读失败/null 会把"已开启"改写成"待检查"（`:77-78`） | 按字段合并，非空值才覆盖 |
| 朋友圈首页 | `moments/moments_page.dart:551` | L4 | 数据保留但渲染红色横幅（`:898-907`） | 去掉横幅赋值，仅 `_feedData == null` 时报错 |
| 个人朋友圈 | `moments/personal_moments_page.dart:111` | L1 L4 | 失败时 `_items = []`（`:112-116`）；首帧只来自调用方内存 | 失败保留 `_items`；补本地页缓存 |
| 朋友圈详情 | `moments/moment_detail_page.dart:99` | L4 | 隐私事件/401/403/404 先把 tile 清空（`:99-107`、`:143-150`），随后刷新失败就一直显示"动态暂不可见" | 保留 tile，降级为非破坏性提示 |
| 日历选择页 | `ui/chat/chat_search_page.dart:738` | L1（部分） | 月份数据本地索引优先但未知日期会探服务端（`matrix_e2ee_client.dart:2872-2873`）；页面只留内存 map（`:775`） | 月份 map 提升到会话级 Store |
| 推荐内容 | `discovery/discovery_page.dart:195` | L1 L3 | 纯静态空态（`:211`），无 store、无刷新 | 若要真做，按 `MomentsUnreadController` 模式加持久化缓存 |

## 3. 已符合（抽样）

个人主页（Me tab，`profile_repository` + `initialProfile`）、头像页、我的二维码、关于页、投诉页、通知设置、通知诊断、联系人资料页、加好友资料页、好友验证页、群地址列表、朋友圈预览卡（peek→ensureFresh）、朋友圈可见范围选择页、朋友圈未读角标、聊天里的财务卡片（`finance_card_store`）、聊天转账详情、发现页、全局搜索的**生产接线**（注入了 identityCache 时）、内存消息搜索索引。

## 4. 现有本地 Store 清单（修复要复用的）

| Store | 位置 | 持久化 | 归属 |
|---|---|---|---|
| `WalletEntryStore` / `WalletEntryStores` | `finance/wallet_entry_store.dart:100,223` | **仅内存**（进程内注册，键 `scope#epoch`） | 无生产 dispose 调用；靠 epoch 换键 |
| `ManualOperationStore` / `WalletNoticeStore` | `wallet/manual_operation_store.dart:9`、`wallet_notice_store.dart:52` | SharedPreferences | 页面持有 |
| `FinanceCardStore` | `finance/finance_card_store.dart:146` | 仅内存、随 RoomPage 销毁 | `room_page.dart:581` |
| `ProfileRepository` / `SqliteProfileStore` | `matrix/profile_repository.dart:364,146` | SQLite `chatflow_profile_v1.db` | `app_home.dart:1387-1413` |
| `CacheRepository` / `MomentsPageStore` | `core/cache/cache_repository.dart:26-30,110` | SQLite + SharedPreferences（**明确排除资金/凭据**，`:24-25`） | 进程单例 |
| `MomentsUnreadController` | `moments/moments_unread_controller.dart:7` | SharedPreferences | `app_home.dart:386` |
| `GlobalSearchIndex` / `LocalMessageSearchRepository` | `search/global_search_index.dart:47`、`local_message_search_repository.dart:147` | 仅内存（可重建） | `app_home.dart:1337-1340` |
| `FriendRequestWatch` | `features/friendship/friend_request_watch.dart:60-61` | SharedPreferences（seen/pending-outgoing） | `app_home.dart:969` |

## 5. 结论（跨页面的系统性缺口）

1. **钱包是最严重的缺口**：`WalletEntryStore` 缓存只活在内存里，进程一重启就没了；断网时既没有可展示的余额/绑定信息，能力位（`depositEnabled`/`payoutEnabled`）也只能来自网络快照，于是"进不去充值/提现页"。用户报告的两个现象（进入即闪烁+错误提示、断网进不去）都能由此解释。
2. **同构缺陷重复出现**：`load(refresh:true)` 先清空、失败即错误页/空态（账本、标签、新的朋友、加好友搜索、邀请码、朋友圈个人页/详情）。
3. **已有本地数据未被使用**：`ProfileRepository.contacts`、`CacheRepository.preferencesSnapshot`、`FamilyCardStore`、本地消息索引都已存在，但标签页/朋友圈设置页/搜索回退仍在走网络。
4. **修复顺序**：钱包（用户直接受影响）→ 账本/账单 → 聊天记录搜索 → 新的朋友/标签 → 邀请码/入群 → 朋友圈四个页面 → 其余 Partial。

---

## 6. 改造进度（逐页落地，每项都有测试 + 反向对照）

模型不变：L1 本地优先 → L2 立即展示 → L3 后台同步 → L4 失败不覆盖。下表"证据"列给出提交与测试文件，测试均做过**反向对照**（临时关掉新分支确认变红，再恢复）。

| 页面 | 状态 | 提交 | 测试 |
|---|---|---|---|
| 钱包充值/提现/绑定（用户报告 #1） | ✅ 已改 | `05fabb3a` | `test/features/wallet/wallet_entry_cache_test.dart`、`manual_wallet_capabilities_test.dart` |
| 钱包「全部账单」 | ✅ 已改 | `af02dc70` | `test/features/ledger/ledger_controller_test.dart`、`ledger_pages_test.dart` |
| 查找聊天记录 | ✅ 已改 | `dd67fdd9` | `test/ui/chat/chat_search_offline_test.dart` |
| 新的朋友 | ✅ 已改 | `cdd0d422` | `test/features/contacts/friend_requests_cache_test.dart` |
| 通讯录标签（成员/选择器/标签列表） | ✅ 三态已改，标签列表持久化未做 | `e8f6f557`、`85bf990e` | `contact_tag_cache_test.dart` |
| 加好友搜索 | ✅ 已改 | `e4fb87ee` | `add_friend_search_test.dart` |
| 扫一扫 → 我的二维码 | ✅ 已改 | `7d8f0cba` | `scan_qr_page_test.dart` |
| 资料页后台刷新失败 | ✅ 已改（保留 `ready` 与旧资料） | `3284fa27` | `profile_controller_test.dart` |
| 通话权限清单 | ✅ 已改（按字段合并，未知不覆盖已知） | `3bedc5ff` | `test/call_permission_readiness_test.dart` |
| 朋友圈：首页 / 个人页 / 详情 / 设置 / 排除名单 / 可见范围名单 / 发动态草稿 | ✅ 已改 | `38f8ccb9`、`8d535bfb`、`aa4cdc94`、`58c3dde0` | `moment_cache_first_test.dart`、`moments_settings_cache_test.dart`、`moment_people_cache_test.dart`、`moment_draft_cache_test.dart` |
| 全局搜索（本地结果先发布） | ✅ 已改 | `1104cf3f` | `test/features/search/global_search_cache_first_test.dart` |
| 邀请码 / 邀请历史 | ✅ 已改 | `c1aa22f3` | `test/features/profile/invite_cache_first_test.dart`（10 例：断网进入无加载圈/无错误占位、刷新失败保留、快照往返、跨账号丢弃、作用域不可解析不落盘、损坏载荷） |
| 红包领取明细 | ✅ 已改（会话级内存缓存，不落盘） | `d6d9cc1a` | `test/features/redpacket/red_packet_detail_cache_test.dart`（8 例：网络回来前先渲染、失败保留、按 packetId 命中、epoch 隔离、拆红包弹窗不注入缓存、断网再进入无加载圈/无重试占位、无缓存首次失败仍可重试、LRU 上限） |

新增本地快照 Store（均为应用私有 SharedPreferences，按账号作用域隔离，账号切换即丢弃）：`wallet.entry.v1.<scope>`、`ledger.page.v1`、`friend.requests.v1`、`moment.draft.v1`、`invite.code.v1`。

会话级（进程内、**刻意不落盘**）Store：`RedPacketDetailStore`（红包明细含群成员金额，属第三方资金展示数据；仓库的 `CacheRepository` 明确排除资金/凭据，故只做会话内复用）。

### 6.1 仍未改造（按剩余价值排序，含复核后的判定修正）

| 页面 | 位置 | 复核后缺口 | 备注 |
|---|---|---|---|
| **提现页「申请状态卡」**（真机新发现） | `wallet/manual_wallet_page.dart:312-315`、渲染条件 `:1945-1973` | **L1**：状态对象 `ManualPayout` 只来自 `api.payout(id)`，无本地快照；已持久化的只有申请操作记录 `ManualOperationStore` | Mi 6 真机 A/B：断网冷启动后余额/步骤条仍在，**状态卡消失**；联网刷新后恢复（`docs/verification/2026-09-19-wallet-offline-device-verification.md` §2，截图 `withdraw-A-offline.png` vs `withdraw-C-online-refreshed.png`）。**实施约束**：不能直接复用 `ManualOperationStore`——它的 `save` 有安全白名单（`manual_operation_store.dart:43-68`，仅 `key/amount/version/id/quote_id/address/method/confirm_key/funding_asset`），写入 `status/review_reason/settlement_txid` 会抛 `ArgumentError`；应新增独立的状态快照 store（键按 `<scope>:payout:<id>`，自带显式非密字段白名单、账号作用域校验），进入先渲染、后台刷新覆盖、失败不覆盖 |
| 通讯录首页 | `contacts/contacts_page.dart:66` | L1 角标 / L4 reload 回退本地投影 | **另一会话正在改**（该文件带未提交改动），本会话按仓库"同一文件不得并发编辑"规则未动 |
| 通讯录标签列表持久化 | `contacts/contact_tag_pages.dart:142` | L1（标签列表本身无持久化） | 三态已就绪，只差落盘；同一文件也带其他会话的未提交改动，避免并发编辑 |
| 日历选择页 | `ui/chat/chat_search_page.dart:738` | L1（月份 map 只留内存） | **本轮确认受阻**：`ChatSearchPage` 本身没有 room 标识（只有 `loadCalendarMonth` 回调），缓存作用域只能由 `room_page.dart` 传入，而该文件正带其他会话的未提交改动。无作用域的月份缓存会造成跨会话串数据，故不做，等 `room_page.dart` 落定后再实施 |
| 入群确认页 | `contacts/group_join_confirm_page.dart:10` | **判定下调** | 复核：`_load()` 只在 initState 与错误态重试时调用（重试按钮只在 `_info == null` 时渲染），因此"已有群信息 + 刷新失败"的组合**不可达**，L4 实际上已满足；首帧 spinner 出现在确实无数据时（模型允许）。剩余 L1（按 token 持久化扫到的群信息）价值有限：token 来自刚扫的二维码、加入动作本身必须联网，且缓存的人数/审批提示可能过期误导。**建议不开工**，除非将来支持"从聊天记录重新打开入群确认页" |

### 6.2 审计误报（结论修正）

- **推荐内容**（`discovery/discovery_page.dart:195`）：原判定 L1/L3 不成立。该页 `_RecommendedContentPage`（`:199-226`）是**纯静态空态**，没有任何数据源、不发起任何请求，因此"无缓存/无刷新"不构成缺陷。若将来接入真实推荐流，再按 `MomentsUnreadController` 模式补持久化缓存。

### 6.3 复现命令

```powershell
# 单页证据（示例）
cd apps/mobile_flutter
C:/src/flutter/bin/flutter.bat test test/features/profile/invite_cache_first_test.dart
C:/src/flutter/bin/flutter.bat test test/features/search/global_search_cache_first_test.dart
# 静态检查（按改动范围）
C:/src/flutter/bin/flutter.bat analyze lib/features/profile lib/core/business_api_client.dart
```

**并发提示**：本仓库同一工作树有多个会话同时改码。`test/features/profile/invite_history_controller_test.dart`、`lib/features/contacts/contact_tag_pages.dart`、`contacts_page.dart`、`app_home.dart`、`lib/features/matrix/*` 等文件在写作时带有**其他会话的未提交改动**，不属于本次提交；本轮提交只包含上表所列文件（逐条 `git add -- <path>`）。

