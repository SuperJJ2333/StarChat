# 畅聊 APP 性能与流畅度专项优化方案

日期：2026-09-11。状态：原始调查与设计基线；后续已进入分批实施。具体已完成项、当前差异、失败与限制以 [任务记录](../../workflow/tasks/2026-09-11-performance.md) 和 [执行计划](../plans/2026-09-11-performance-execution.md) 为准。本文阈值仍是验收目标，不是真机实测结果；原“未实施/仅方案”描述仅表示制定方案时的状态。

## 1. 范围、证据与目标

覆盖会话列表、聊天页、朋友圈、个人资料页、图片/视频/文件浏览。基线为工作树 `.worktrees/moments-im-mi6-20260910`，提交 `7bc73ec3`，对应最近交付记录中的 Android 0.3.83-debug / 2087；用户发生问题的具体安装版本仍需确认。主工作区后续未提交改动不等于设备现状。

以下“代码已确认”表示静态源码存在对应路径；“待采样”表示尚未证明它是该设备症状的直接触发点。所有耗时、内存及掉帧数字均为建议验收目标，不是实测结果，也不是 Telegram 官方性能数据。本任务仅调查并输出方案，不修改业务代码、不部署、不操作真机。

目标：先消除错误的缓存加载链和大范围状态更新，再建立统一调度与预算。复用 Flutter、Matrix SDK、本地 SQLite/SQLCipher 和已有内容哈希缓存，不替换通讯协议，不引入第二套消息权威存储。

## 2. Telegram 机制与畅聊适配

| 场景 | 官方公开机制 | 畅聊迁移方式 |
| --- | --- | --- |
| 本地消息与资料 | TDLib 可分别持久化文件信息、用户/群资料、消息；历史接口支持 only_local | 直接采用先读本地、订阅变化的原则；继续使用 Matrix SDK 消息数据库，业务资料保留既有 ProfileStore，不能直接移植 TDLib 数据模型 |
| 历史分页 | TDLib 用消息锚点读取历史，单次 limit 最多 100，可能返回不足请求数 | 适配 Matrix 历史游标、缺口及 SDK 顺序，初始 30–50 条，滚动预取；不能把 Telegram 消息 ID 排序搬成 Matrix 时间戳排序 |
| 会话列表 | TDLib 根据 chat position 更新顺序，并按需 loadChats | 维护 roomId 对应的会话摘要投影，仅更新脏会话；保留置顶、未读、草稿及最近活动的产品排序规则 |
| 图片缓存与加载 | Android ImageLoader 有多个 LRU、按 URL/key 合并加载、缩略图及后台任务队列；结果分发给 ImageReceiver | 采用统一请求合并、缩略图优先和结果订阅；映射为 Flutter ImageProvider、解码尺寸和生命周期管理 |
| 文件下载 | TDLib downloadFile 提供 1–32 优先级、offset/limit，通过 updateFile 报告状态 | 采用可提升优先级的加载任务和进度流；Matrix 加密附件须先遵守完整性校验，不默认支持明文式任意分片播放 |
| 列表与输入 | Android ChatActivity 使用 RecyclerListView，输入由单独 ChatActivityEnterView 管理；MessagesStorage 有存储队列 | Flutter 保留懒构建列表，拆分消息、输入及头部订阅；用工作 isolate 承担适合的 CPU 任务，不照搬 Android View 复用机制 |

来源：[TDLib 本地存储参数](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1set_tdlib_parameters.html)、[历史分页](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1get_chat_history.html)、[会话列表维护](https://core.telegram.org/tdlib/getting-started)、[下载接口](https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1download_file.html)、[ImageLoader](https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/messenger/ImageLoader.java)、[MessagesStorage](https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/messenger/MessagesStorage.java)、[ChatActivity](https://github.com/DrKLO/Telegram/blob/master/TMessagesProj/src/main/java/org/telegram/ui/ChatActivity.java)。

边界：TDLib 与 Telegram Android 独立客户端实现分别作为参考，不能声称官方 Android 全部使用 TDLib。公开 ImageLoader 存在 URL/path key，不能声称 Telegram 所有媒体都按内容 SHA-256 去重。内容哈希是畅聊已有能力及本方案的统一方向。Telegram 没有与朋友圈完全相同的产品面，朋友圈复用其缓存与调度原则即可。不直接复制第三方源码。

## 3. 整体缓存与加载架构：问题 → 根因 → 方案 → 验证

### 问题与根因

代码已有头像缓存、朋友圈快照、媒体哈希对象、请求合并及 ListView/SliverList 懒构建。问题不是简单的“没有缓存、没有虚拟化”，而是：缓存分散，部分网络异常覆盖可用数据；全页订阅扩大重建范围；内存预算分别管理；持久缓存标识、账号隔离和重试语义不统一。

`media_cache.dart` 默认普通媒体内存预算 64 MiB，另有视频内存预算 256 MiB，Flutter 解码图像和播放器另占空间。不能把这些预算当作整体内存上限。2 MB GIF 的压缩大小也不能代表解码内存；12 MP 静态 RGBA 位图本身约 48 MB。

### 方案与关键结构

继续使用现有 SQLite 封装和 SDK SQLCipher；不为同一 Matrix 消息再建一份完整明文镜像。新增结构名称为设计建议，并非当前已有类：

```text
IdentitySnapshot(accountId, userId, revision, avatarState, avatarRef)
PageSnapshot(accountId, scopeId, orderedIds, cursor, revision, refreshedAt)
MediaObject(accountId, contentSha256, filePath, byteSize, lastAccess)
MediaReference(accountId, resourceId, contentSha256, variant, revision)
LoadState<T>(data, refreshing, refreshError, source, revision)
FlightKey(accountId, resourceId, rendition)
DecodeKey(blobIdentity, physicalWidth, physicalHeight, crop, framePolicy)
```

| 层级 | 内容与选型 | 策略 |
| --- | --- | --- |
| 内存展示层 | Flutter ImageCache、可见行模型、头像投影 | 按字节限制解码图；低端设备初始建议 48–64 MiB；离屏 GIF 暂停；不能仅限制图片张数 |
| 内存字节层 | 复用 MediaMemoryCache | 普通压缩媒体初始建议 24–32 MiB；视频优先文件引用，避免整段视频重复 readAsBytes；与展示层统一观测预算 |
| 磁盘对象层 | 现有账号隔离 SHA-256 文件对象及引用索引 | 一内容一实体；临时文件校验后原子发布；引用计数保护正在播放/发送文件；LRU 清理 |
| 数据库元数据层 | Matrix SDK 数据库、ProfileStore、朋友圈分页缓存 | 资料版本、消息游标、朋友圈条目/分页关系及删除标记；索引至少覆盖 accountId+scopeId+排序键 |

上述内存数字只是 Mi 6 首轮调优起点，需同时记录 decoded/live image、native、GPU 和播放器内存。磁盘自动缓存建议先试 512 MiB 软上限，按剩余空间收缩；用户明确下载的文件单独管理，不被自动缓存清理误删。

身份、内容与传输分开：磁盘 key 使用账号命名空间加内容哈希；有权限的账号内共享同一对象。相同内容不同文件名应合并，同名不同内容不能合并。解码 key 必须包含实际尺寸等参数，避免为小头像解码大图。传输 URL、签名有效期、Authorization 不进入内容标识；不能任意剥除有业务含义的 URL 参数。Matrix 随机加密后的不同密文不保证同 hash；明文内容 hash 只在本地或获准的端到端加密元数据内使用，不泄露给业务服务器。

加载顺序：

```text
进入页面 → 读取已恢复的账号作用域 → 读取本地快照 → 立即发布可用内容
         → 订阅该页面需要的实体变化
         → 后台重新校验 → 校验账号/版本 → 事务写入 → 发布增量
后台失败 → 保留 data，仅设置 refreshError；没有 data 才显示空态/离线态
```

建议软刷新窗口：资料 5 分钟、朋友圈 30–60 秒，按业务事件即时失效。软过期不等于删除可用离线数据。内容 hash 不变的媒体无需按时间重新下载；磁盘保留期是容量策略。已知删除、隐私权限变更、退出账号应优先失效，不能用旧缓存恢复已知无权查看的内容。

统一调度：P0 当前用户点开的媒体/可见缺失数据；P1 可见头像与缩略图；P2 相邻一屏缩略图/前后各一张预览；P3 后台整理。消息文本和输入不等待媒体。网络并发初始 3，视频占用最多 1；图片准备任务初始 2，实测调整。相同任务共享 Future，多个消费者引用计数；离屏取消消费者，最后一个消费者退出才中止请求；预取任务进入可见区时提升优先级。弱网取消远距离预取，不取消用户显式下载。

### 验证标准、收益与风险

暖缓存已知 hash 媒体重复展示/发送：新增媒体下载字节为 0，磁盘实体保持 1；只在未被淘汰且解码参数一致时要求复用解码缓存。未知 hash 首次接收、清理后或容量淘汰后允许重新下载。动画本身的逐帧解码不能记为错误重复下载。

连续进出页面 10 轮，稳定后内存相对第 2 轮增长目标不超过 10%，缓存不得随相同媒体发送次数线性增长。风险集中在账号隔离、失效一致性、活跃文件淘汰和迁移：采用新版本索引双读迁移、失败回退旧读路径；不清空用户已有数据来掩盖问题。预计 5–8 人日，不含完整回归。

## 4. 已知问题一：头像一直默认，重新进入才正常

### 问题与根因

已确认：`matrix_user_avatar.dart` 有异步完成后的 setState，因此不能归因为“完全没刷新”。但解析失败后只记录错误，属性未变化时没有重新解析触发；重新进入会重新 init，符合用户所述恢复路径。

已确认：`profile_repository.dart` 的加载将个人资料、联系人放在 Future.wait 中，两个均成功才发布；联系人慢或失败会拖住已成功的个人资料。该仓库已有 SQLite 持久化及监听，不能重新造一套缓存。

已确认：`avatar_url_resolver.dart` 的缓存保存 Future，key 没有账号/会话代次且返回结果可携带认证头，需检查失败 Future 淘汰和重新登录后的凭据更新；是否经过该方法需追踪真实调用链。`avatar_cache.dart` 使用 URL.hashCode 作为部分版本值，持久标识应改成稳定摘要或服务端版本。

待验证：问题用户是本人还是他人、业务头像与 Matrix 成员头像何者权威、是否触发失败缓存或资料发布阻塞。`room_page.dart` 已监听身份仓库，不能把“组件实例不同”直接当作本问题原因。

### 改造方案

1. `ProfileRepository` 按用户发布资料增量；本人资料与联系人结果分别落盘、分别通知，沿用账号 generation 防串号。业务确认的头像删除必须成为明确状态。
2. 使用 `AvatarState = unknown | none | present(ref, revision)`。unknown/加载中可保留同用户上一张有效图；none 立即显示默认图；present 按版本更新。不能用 Matrix 旧头像覆盖业务明确删除。
3. 新建按 `(accountId,userId)` 的细粒度 watchIdentity，头像完成只重建该头像，不通知整个房间。
4. 先读资料数据库、内存图片和磁盘文件；随后后台校验。失败移除 inflight，网络恢复或显式刷新时重试；退避重试且离屏停止。授权失败先走现有凭据恢复链，禁止无限重试。
5. URL 解析与认证头分开，下载时注入当前凭据；widget 对 identity revision、账号代次变化重新订阅。异步完成校验 mounted、requestGeneration 和当前 userId。
6. `UserAvatar` 保留 gaplessPlayback；缓存 miss 的首次默认图合理，目标是结果到达后必须更新，而非承诺冷启动永不显示占位。

### 验证指标

记录 identity hydrate → avatar bind → disk/network result → decode → first paint，区分本人/联系人/群成员。暖磁盘头像 p95 首次有效显示 ≤150 ms；有效异步结果到达至画面更新 p95 ≤100 ms。冷网络下载耗时单独报告，不与本地 UI 延迟混算。

覆盖：首次进入、换头像后留在房间、头像删除、联系人接口失败但本人资料成功、断网再联网、快速切换用户、杀进程恢复、多账号登录。100 次受控重复中不得出现“数据成功返回但一直默认直到重进”。预计 2–3 人日；主要风险为错误回退到被删除头像及跨账号缓存。

## 5. 已知问题二：断网页面无法使用缓存、图片反复刷新

### 问题与根因

已确认：`room_page.dart::_load` 在创建 timeline 并结束 loading 后，继续等待 markRead、表情/提醒等操作；外层 catch 会设置全页 errorMessage。build 优先显示错误，因此后续网络失败可能盖住已经可用的本地消息。需通过断网与逐依赖故障注入确认实际抛错点。

已确认：`moments_page.dart::_initializeFeed` 已读取账号缓存，刷新失败也保留旧 feed，不能整体推翻为网络优先。`cache_repository.dart` 的朋友圈缓存主要是近期首页快照，历史分页缺乏完整持久化覆盖；账号未完成本地恢复、缓存被正确清理、媒体未下载也会产生不同离线表现，需要分别统计。

### 改造方案

1. 拆分聊天页关键加载与附属任务。timeline 可用就显示；markRead 加入现有同步/重试渠道，表情、提醒、资料失败使用各自状态，不能写全页消息错误。
2. 保持 `data + refreshing + refreshError`，刷新期间不将 data 清空，不替换列表 key，不重新建立每张图片的下载 Future。
3. Matrix 历史优先查询 SDK 本地数据库，缺页才请求历史；离线到缓存边界显示“更多历史暂不可用”。不假造全量历史，不用网络身份请求阻塞已恢复账号的缓存。
4. 朋友圈将现有快照渐进迁移为 SQLite 条目、分页关联、cursor、revision 和 tombstone；持久化已浏览分页，保留现有账号及隐私失效保护。页面先读最近一页，向下按本地 cursor 加载。
5. 媒体组件仅订阅统一 repository；warm cache 不淡出再淡入。无本地原图但有缩略图时保留缩略图并标记离线；完全无缓存展示固定尺寸占位，避免高度跳动。
6. 文件列表先呈现本地元数据，点击时命中本地文件优先打开；下载进度持久引用同一任务，进入其他会话不重复开启。

### 验证指标

已登录且缓存存在、断网后杀进程重进：缓存消息/朋友圈可见内容完整恢复率 100%；此指标只覆盖确实持久化且未被权限失效的数据。路由暖进入首批文本 p95 ≤200 ms，朋友圈磁盘暖首屏 p95 ≤300 ms；进程冷启动到本地首屏另测，首轮目标 ≤800 ms，不包含用户解锁动作。

分别让已读、资料、表情、朋友圈刷新失败：已有内容不能变成全页错误。已缓存相同媒体重复进出 10 次，下载次数 0；首次下载并发请求合并为 1。清缓存后的离线空态属于正确行为。预计 3–5 人日；风险为历史游标缺口、隐私删除和离线写入重试幂等性。

## 6. 已知问题三：高负载群聊逐字输入卡顿

### 问题与根因

已确认：`WechatComposer` 自身有局部刷新；`room_page.dart::_handleComposerChanged` 主要在 @ 面板状态改变时才 setState，并不是每个字符必定全页重建。

已确认：`room_draft_store.dart::save` 每次文本修改做 JSON 编解码复制；300 ms 防抖只延迟磁盘写，不消除输入路径上的序列化及分配。长草稿和 mention token 更容易放大开销。

已确认：`RoomTimelineController::_snapshot` 全量取消息、匹配 local echoes、去重并排序；refresh 无无变化过滤即通知。`room_page.dart::_changed` 进一步遍历消息并刷新全页。findChildIndexCallback 用 indexWhere 线性找索引；身份仓库变化同样触发全页更新。高频收消息与输入同时运行时会竞争帧预算，直接因果仍须采样。

已有 ListView.builder 虚拟化和历史预取，所以应优化模型窗口及重建粒度。待采样方向：mention 搜索/文本 diff、GC、100 ms 可见性定时任务、缩略图准备、播放器/图片解码、原生输入法线程与 Flutter UI/raster 竞争。

### 改造方案

1. 分离 ComposerController、TimelineViewportController、RoomHeaderController；输入状态留在 composer，消息行按 stableId+revision 订阅。普通输入不触发消息行 build；@ 搜索才使用预建成员索引。
2. 草稿用类型化不可变快照替代每键 JSON 往返；300–500 ms 后序列化和写入，退出/后台强制 flush。保留 TextEditingValue 的 selection、composing，绝不延迟输入回显或破坏中文拼音组合态。
3. 消息维护 orderedIds、messageById、indexById、pendingByTransactionId。新增/修改/撤回只替换受影响实体；SDK gap 或大规模重同步才重建窗口。顺序遵守 SDK，维护本地 echo 到服务器 event 的稳定映射。
4. UI 投影初始 30–50 条，视窗前后按需扩展；首轮最多约 150–300 条活动模型。历史完整留在 SDK 数据库，引用回复/搜索跳转另开锚点窗口。淘汰前保护当前滚动锚点，不能在用户阅读时跳动。
5. 将批量 sync 更新合并到一帧一次发布，突发事件最大等待 50 ms；本地发送 echo 立即反馈。read receipt、typing、头像、状态栏不触发整段消息排序。
6. 合适的哈希、较大 JSON 和纯 Dart 数据变换交给长期工作 isolate；使用 TransferableTypedData 降低大字节复制。先检查 SDK/插件线程能力，UI 与 dart:ui 留在主 isolate。async 本身不意味着 CPU 工作离开主线程。
7. GIF 离屏暂停，可见动画初始最多 2 个；视频以海报展示，一个活跃播放器。缩略图按照物理像素解码，禁止头像路径解码原尺寸照片。

参考：[Flutter 局部更新和懒构建](https://docs.flutter.dev/perf/best-practices)、[isolate 适用范围和限制](https://docs.flutter.dev/perf/isolates)。

### 验证指标

Mi 6，60 Hz，同一 profile 构建对比：输入事件进入客户端至字符呈现 p95 ≤50 ms、p99 ≤100 ms；同时测真实 IME 到屏幕端到端时间，不能拿回调耗时冒充输入延迟。稳定输入/滚动错过帧截止率 <1%，突发消息场景 <3%；UI、raster 阶段各 p95 目标 ≤8 ms，并单独统计真实错帧，不能只报告平均 FPS。客户端主 isolate 非必要同步长任务不得超过 50 ms。

普通字符输入引起的消息行重建数为 0；单条内容更新只影响对应行和必要聚合 UI，追加一条消息不得对全部历史重新排序。预计 4–6 人日；主要风险是 IME、消息顺序、滚动锚点和 local echo 重复。

## 7. 五类页面的具体交付点

| 页面 | 代码方向 | 额外验收与成本 |
| --- | --- | --- |
| 会话列表 | matrix_home_page.dart 的 _refreshClientSnapshot 从全量 room 投影转为 dirty room 摘要更新；保留 ListView.separated；群头像只处理可见行 | 500 会话暖首屏 p95 ≤300 ms，单房间新消息不重建全部会话项；2–3 人日，注意置顶/未读排序 |
| 聊天页 | room_page.dart、room_timeline_controller.dart、room_draft_store.dart、wechat_composer.dart | 按上述头像/离线/输入门槛验收；与前述成本重叠，不重复计费 |
| 朋友圈 | moments_page.dart、cache_repository.dart、moment_media_cache.dart | 已浏览分页离线恢复，追加分页不闪烁既有图片；3–5 人日与离线/缓存阶段重叠 |
| 个人资料页 | ProfileRepository、MatrixUserAvatar、UserAvatar；统一身份版本及细粒度订阅 | 缓存资料首屏 p95 ≤200 ms，修改头像跨入口一致；1–2 人日，保持按钮/好友关系业务逻辑 |
| 图片/视频浏览 | 复用 wechat_moment_viewer.dart 及会话媒体入口、media_cache.dart、video_poster_*；建立按房间排序的媒体引用窗口 | 当前图优先，前后各一张有预算预取；只为当前视频持有活跃控制器；暖图 p95 ≤150 ms；3–4 人日，注意 E2EE 校验和滑动边界 |

图片浏览先呈现缓存缩略图，再替换当前原图；不要打开浏览器就解密整间房所有原图。视频海报与本体是不同内容对象，各自只生成/缓存一次；不能把不同分辨率产物硬合成同一个 decode key。文件主动下载与自动预取分级，蜂窝网络默认仅预取轻量缩略图，具体策略待产品确认。

## 8. 定位、回归与验收方法

工具：Flutter DevTools Performance/Memory、FrameTiming、Android Perfetto；服务层增加结构化 cache hit/miss/inflight join、下载字节、排队/解密/解码时长、重建行数、DB 查询耗时。只记录不含正文、令牌、完整 URL 或钱包地址的统计标识。性能对比使用相同 profile/release 配置，debug 只用于功能交付，不用于通过性能门槛。

测试数据：500 个会话，50 个活跃群，目标群 1000 成员、服务端历史 5 万条，客户端投影窗口受限；持续 20 条/秒 60 秒，另加 100 条/秒 5 秒突发。输入 1000 次操作，覆盖中文组合输入、emoji、退格、粘贴 1 万字草稿、@ 成员；群规模不足时用脱敏合成数据，不复制私人消息。

矩阵：首次无缓存、进程冷启动但磁盘有缓存、路由暖进入分别统计；强网、弱网、断网、恢复；发送端/接收端；切会话、杀进程、多端资料/撤回同步。继续检查撤回提示不消失、唯一私聊房间、已读/未读、消息顺序、资料按钮和朋友圈自己评论长按规则，避免性能改造回归前序功能。

媒体矩阵：2 MB 同 GIF 连发 10 次、同视频往返、异名同内容、同名异内容、跨会话、清缓存后、淘汰后、账号切换。分别记录网络请求、磁盘对象数、decoder 创建次数、动画实际帧解码、内存峰值，不把合理动画播放成本算成重复下载。

每场景至少 30 次有效样本，报告 p50/p95/p99、样本量、冷热缓存状态、构建 hash、设备温度和电量；长压测另跑 10 分钟。p99 在 30 次样本中仅作观察，最终输入等高频事件使用至少 1000 个样本评估。记录优化前后相对改善，首屏与输入 p95 目标改善 ≥30%，但基线已低于绝对门槛时以不回退为准，不能承诺未经测量的收益。

## 9. 优先级、阶段和风险控制

| 阶段 | 工作 | 出口条件 |
| --- | --- | --- |
| P0 / 1–2 人日 | 构建基线、埋点、可重复离线与高负载夹具 | 三症状均有可追踪链；无法复现项明确标为未证实 |
| P0 / 4–6 人日 | 分离聊天附属失败、头像独立发布及重试、首屏保留缓存 | 离线内容不被覆盖，成功头像结果无需重进 |
| P1 / 4–6 人日 | 草稿序列化移出逐键路径、状态解耦、增量时间线 | 达到输入/重建门槛且 local echo/IME 不回归 |
| P1 / 5–8 人日 | 缓存统一预算、媒体调度、朋友圈分页持久化 | 去重、离线历史和账号隔离通过 |
| P2 / 3–5 人日 | 会话列表摘要增量、资料页/浏览页预取与生命周期 | 五页面均有可比较基线与回归记录 |
| 收口 / 3–5 QA 人日 | 长压测、弱网、多端及内存回归 | 发布证据明确通过项、失败项、限制项 |

研发合计约 17–27 人日，另加 3–5 QA 人日；初步按两位客户端开发和一位 QA 规划约 3–5 周，实际取决于 Matrix SDK 扩展点及数据库迁移难度。后端先仅核对头像版本、媒体引用契约，确需接口扩展再单列工作量。

按 repository 接口分段交付、配置开关回退新调度器；数据库使用扩展迁移，不破坏旧缓存读取。E2EE、权限和身份恢复逻辑不作为性能捷径绕过。若后续涉及加密存储协议变更，需单独设计和对应安全评审。

## 10. 实施前需补充的信息

1. 三个现象对应的安装版本、本人或他人头像、出现概率；是否包括 iOS。
2. 实际会话数、目标群人数、历史量、消息峰值；是否伴随 GIF/视频和长草稿。
3. “断网不可用”发生在同进程重进还是杀进程、是否退出账号/清缓存；哪些内容此前确实已浏览并持久化。
4. 头像接口是否有稳定 revision/ETag；自定义头像与 Matrix 成员头像的权威来源及删除语义。
5. 端到端加密媒体元数据是否稳定携带内容 hash；不同端是否一致保留该字段。
6. 自动缓存容量、用户主动下载保留策略、蜂窝预取偏好、最低支持机型。

这些信息影响阈值和实施细节，不妨碍先落地已识别的局部加载失败隔离、头像失败重试及逐键序列化优化。当前仅完成源码分析和方案，未宣称任何真机验收通过。
