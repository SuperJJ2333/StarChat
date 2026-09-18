# 移动交付恢复索引

## 2026-09-18 Media Engine Phase 4 — Full Implementation（服务端 Media Platform；**本地完成，未构建/未真机/未部署**）

用户任务：实现 ChatFlow Media Platform（能力完整实现 + **Strangler Pattern** 渐进迁移），严格遵守 Phase 3.1 的
ADR-001…ADR-006；**5 个可构建提交**；禁止全球明文去重 / E2EE 服务端处理（解密·转码·生成变体）/ 迁移 Matrix 字节 /
改 Matrix 协议 / Avatar 接入（延期）/ 分片上传实际传输（本阶段只做接口）。
**提交**：`bf397700` domain core → `88a6b0c7` gateway → `850935e7` reference lifecycle →
`e8284bbb` authorization → `dfbcf4f6` moments integration。
**实现**：① **4.1** `MediaObject`/`MediaBlob`/`MediaVariant` + 三种 `digest_kind`
（`plaintext_digest`/`ciphertext_digest`/`transport_digest`，`Digest.__eq__` 跨类直接抛异常 ⇒ "明文 hash == 密文 hash"
在类型层不可能）+ 隔离域地址（键含 `media/{user|e2ee|public}/<scope-hash>/…`）+ 策略（去重/ TTL / 选档）+
指标（`media_resolve_ms`/`variant_resolve_ms`/`authorization_ms`/`cache_hit`/`storage_read_ms`，无 PII）+
**expand-only 迁移 0069**（7 张新表，含 3 个部分唯一索引；未改任何既有表）。
② **4.2** `MediaGateway`（`resolve`/`authorize`/`resolve_variant`）+ `BusinessMediaGateway` +
**`MatrixMediaGateway`（只读：解析 `mxc://` + 授权委派给 Matrix，平台不为 E2EE 字节建身份、不复制不重加密）** +
Variant Resolver（ready-only，授权范围只收窄）+ **独立 Upload Engine 接口**（会话/续传/abort 可用；
分片与 commit 返回 501 并在响应中声明 `chunk_upload_supported=false`）。
③ **4.3/4.6** 引用系统（`observed`/`declared`、幂等 active 唯一、引用计数可重算、按业务释放只作用于调用者自己的引用）
+ 生命周期（`ACTIVE/ORPHAN/DELETING/DELETED`，`QUARANTINED`/`PINNED` 正交）+ `MediaGarbageCollector`
（dry-run / audit `media_gc_runs` / 恢复 `DELETING` / E2EE 保留下限 / 引用·pin·隔离·在途上传保护）。
④ **4.4** `AccessGrant`（owner 专属签发、撤销递增版本）+ **Signed URL**（HMAC 绑定
`media_id+variant+subject+permission+tier+expire+jti+grant_version`；**API 无 `expires_in` 参数**⇒ 服务端唯一决定 TTL；
**private 要求调用方身份 == subject（转发无效）**，**audience 允许受众内转发但撤销即时生效**；篡改/过期统一 404）。
⑤ **4.7** Moments 零侵入接入：新上传经平台（对象+blob+变体+引用），既有 `moment_media_uploads` 只增加一行
**指向平台 blob 键**的 COMPLETED 记账行，返回既有 capability URL ⇒ **未改任何 Moments 代码**，
既有 `POST /moments` 与 `GET /moments/media/content/{token}` 直接服务平台字节（一份字节、两条读取路径、可回滚）。
为兼容既有读者，平台键加 `moments/` 命名空间前缀，隔离地址仍保留在路径中。
**测试**：新增 **71 条**（5 个文件），覆盖任务书 Test 1–8 与 §13 安全要求（越权/转发/TTL/删除隔离）；回归
`tests/business_api/moments`+`media` **106 条全通过（未改其中任何文件）**，合计 **177 passed**。
**门禁**：见下方"门禁执行记录"。进入
[任务记录](tasks/2026-09-18-media-engine-phase4-implementation.md) 或
[实施报告](../verification/media-engine-phase4-implementation.md)。

## 2026-09-17 Media Engine Phase 3.1 — Architecture Freeze（**只冻结，不编码**；文档完成）

用户任务：**冻结架构边界**，为 Phase 4 Implementation 提供稳定架构依据；**本阶段只设计，不编码**
（禁止修改 Matrix Server / 协议 / E2EE / Megolm·Olm / 媒体上传接口 / Moments API / Avatar API /
数据库 schema / 客户端缓存代码 / Flutter 业务代码；禁止实现 Media Gateway / Media Object Server /
Upload Engine / CDN / 远端去重）。
**交付物**：[`docs/architecture/media-engine-phase3-freeze.md`](../architecture/media-engine-phase3-freeze.md)
（9 节结构 + 冻结报告；6 条冻结记录 ADR-001…ADR-006，覆盖用户清单的 15 个决策 D-01…D-15）。
**已冻结决策**：① **ADR-001 隔离**——第一阶段正式方案 = **隔离域模型**：明文域 = Option A（用户空间隔离，
跨用户零共享字节），密文域 = 保留已上线的密文摘要跨用户复用（受限 Option B），**明确拒绝 Option C 全球去重**；
「隔离（存哪）≠ 授权（谁能读）」被显式分离。② **ADR-002 Digest**——三种 `digest_kind`
（`plaintext_digest` / `ciphertext_digest` / `transport_digest`）各自明确"谁算/可信度/谁能访问/用途"，
**种类永不互相比较**，禁止 `plaintext hash == cipher hash`，客户端摘要永不作权威，不提供客户端存在性查询；
去重边界 = 不做全球 dedup + 明文域只做用户空间 dedup + 密文域只做密文对象复用（确定性信封 + 门槛）。
③ **ADR-003 Authorization**——读取流程五段（Client → Authorization → Media Resolver → Variant Resolver →
Signed URL → Download）；Signed URL 至少绑定 `media_id + subject + expire + signature`；**TTL 服务端唯一决定**
（写相对策略不写固定数字）；转发**分级**：`audience` 允许（含风险声明）、**`private` 禁止**（以
"令牌 subject 必须与调用方身份一致"实现）。④ **ADR-004 Matrix 兼容与接入**——兼容 = **永不迁移字节 +
惰性建索引 + 字节不双写 + 双读**；`MatrixMediaGateway` / `BusinessMediaGateway` 适配结构；
**Moments = Phase 1 接入**；**Avatar 延期**（TTL/高刷新/CDN/权限与收益≈0）；**E2EE 视频变体只能由发送端生成**；
CDN 链路 `Storage → Media Gateway → CDN → Client` 且 **CDN 不参与授权**。⑤ **ADR-005 Upload Engine**——
**独立子系统**（UploadSession/Chunk/Resume/Checksum/Encrypt/Commit；E2EE 先加密再分片且保持 CTR 计数器连续）；
1GB+ 能力全部属 Phase D，本阶段不实现。⑥ **ADR-006 删除与生命周期**——删除 = 解引用
（Remove Reference → Check → Mark Orphan → GC）；状态集 `ACTIVE/ORPHAN/DELETING/DELETED`，
`QUARANTINED`/`PINNED` 为正交属性；`SCANNING` **保留但必须有生产者 + 超时兜底 + 存量清理，E2EE 域不得引入**。
另冻结：架构原则 P1–P10、安全不变量 I1–I10、性能约束 PF1–PF6、安全威胁模型七项（含对策与残余风险）、
性能目标（缩略图缓存命中 <100ms、poster <50ms、千人群回源 ≤1 次/边缘节点、万人回源 ≤5%）、
迁移 A→E 与逐阶段回退、**15 项 DEFERRED（Phase 4 不得实现）**、Phase 4 可实现 13 条 / 禁止 15 条。
**门禁**：本阶段未改任何代码/配置/schema，故未运行 Flutter/仓库门禁；仅做结构、编号、覆盖度与禁用措辞自检
（"设计完成" 0 命中）。最后代码门禁 = Phase 2 全量 3120 通过 + `scripts/verify.ps1` PASS。
进入 [任务记录](tasks/2026-09-17-media-engine-phase3-1-freeze.md)。

## 2026-09-17 Media Engine Phase 3 — 服务端媒体对象基础设施（**只设计，不编码**；本地文档完成）

用户任务：设计未来的**服务端媒体对象基础设施**（Chat / Moments / Avatar / File 共用的
Media Object / Variant / Reference / Permission / Lifecycle / Storage / CDN），
目标形态 = Telegram / 微信级的媒体对象体系 + 多版本媒体体系 + 权限体系 + 生命周期体系，
同时保持 **E2EE 安全 / Matrix 兼容 / 渐进迁移 / 不破坏已有用户数据**。
**本阶段明确：Architecture Design Only（只设计，不编码）**，禁止修改 Matrix Server / Matrix 协议 / E2EE /
媒体上传接口 / 朋友圈 API / 数据库 schema / 客户端缓存代码；**不实现**全球媒体去重 / CDN 改造 / 服务端对象迁移。
**交付物**：① [`docs/architecture/media-engine-phase3-server-audit.md`](../architecture/media-engine-phase3-server-audit.md)
（只读现状审计：三条上传链路 Chat/Moments/Avatar + File；存储在哪 / 谁管生命周期 / 谁删除 / 谁控权限 / 是否可复用；
基础设施与容量基线；风险 A1–A18；未确认项）；
② [`docs/architecture/media-engine-phase3-server-design.md`](../architecture/media-engine-phase3-server-design.md)
（17 章设计：Current Architecture / Problems / Goals / MediaObject / MediaVariant / MediaReference /
Encryption Dedup Analysis（方案 A/B/C 技术分析，**不选型**）/ Permission Model / Lifecycle / Upload Protocol /
Download Protocol / CDN Design / Database Schema / Migration Strategy（Phase A→D）/ Security Analysis /
Performance Analysis / Phase 4 Roadmap，另附目标架构图、术语表、10 个开放决策）。
**关键审计结论**：E2EE 链路中**服务器从不收到明文摘要**（`chatflow_media` 在 Megolm 密文内；上传只带密文）；
Matrix 侧**已存在**可用骨架（密文摘要索引 + 逐用户引用 + 宽限期 + 隔离墓碑 + 崩溃恢复，`third_party/synapse/chatflow_media_dedup.py`）；
业务侧（Moments/Avatar/压缩演绎版）**零内容寻址、零引用计数、零 GC/配额/计量/指标**，三个读取端点**无鉴权**，
头像/渲染 TTL 可被客户端拉到 7 天，朋友圈引用写入不校验 TTL（过期链接可"洗白"成永久引用）；
朋友圈删除**不删字节**、封面替换**不删旧对象**、`SCANNING` 状态**无生产者**；
客户端**没有任何可续传上传**（失败即整请求重试，60 s / 20 s 总时限），而 Synapse 上传上限 **50 MiB** ⇒ 1GB+ 视频当前不可能。
**设计要点**：三层 Object/Blob/Variant 拆分 + `digest_kind`（明文/密文摘要**永不混用**，5 条强制规则）+
`dedup_eligible`（随机信封不参与去重，Emoji 保险库即是实例）+ observed/declared 两级引用（承认 E2EE 引用不可数）+
fail-closed 授权（Grant + 变体级授权 + 令牌绑定 subject/TTL/次数）+ 三段状态机 + 会话式分片上传（与确定性 CTR 计数器连续性约束）+
poster→preview→档位→原片的渐进播放（**E2EE 域只能端侧生成**）+ L1/L2/L3 CDN 分级（受众级 URL 换取命中率）+
7 张表 DDL 草案 + Phase A/B/C/D 迁移（可回退、不搬字节、不重加密、旧数据永远可读）+ 逐项安全分析 + 容量模型与指标。
**门禁**：本阶段**未改任何代码/配置/schema**，故未运行 Flutter/仓库门禁（按仓库"文档改动只需链接与一致性检查"规则）；
最后代码门禁 = Phase 2 的全量 3120 通过 + `scripts/verify.ps1` PASS，工作树此后未再变更代码。
按用户本轮授权，改动已分逻辑提交并推送到 GitHub `main`。进入
[任务记录](tasks/2026-09-17-media-engine-phase3-server-design.md)。

## 2026-09-17 Media Engine Phase 2（本地媒体索引 / 账号配额隔离 / 缓存生命周期）（本地完成，**未构建/未真机/未部署/未 push**）

用户任务：**建立可靠的本地媒体索引体系，消除大文件缓存命中时重复 SHA-256 计算，修复多账号共享磁盘配额，
逐步统一 Chat / Moments / Avatar / File 的本地缓存生命周期**（明确**不做 Phase 3**：服务端 SHA 去重 /
跨用户复用 / 远端内容寻址只设计）。
**P0-1（大文件命中不重哈希）**：新增 `MediaIndex`（SQLite，表 `media_index`，主键
`(account_namespace, reference_key)`，schema v1，**懒打开不启动扫描**），`MediaCache.cached()` 增加索引快路径
`_cachedViaIndex`。**关键自我纠正**：第一版对所有尺寸用"大小 + mtime"放行，导致 3 条既有 Phase 1 完整性用例
失败（`content_addressed_media`×2、`video_poster_pipeline`×1）——毫秒粒度锚点无法分辨"校验同一毫秒内被同尺寸改写"，
对小文件等于让"同尺寸篡改必被发现"退化。最终**分级**：< 1 MiB（`_cheapPathMinBytes`）仍**整文件校验**，
≥ 1 MiB 才用 mtime 锚点（已索引对象 mtime 只在写入时设定，LRU 走索引列，`setLastModified` 只作用于未索引对象）；
`loadMediaWithCache` 的内容摘要复核作最后兜底（不符 → 删对象 + 失效索引 + 重新解密落盘 = **自愈修复**，不抛异常）。
`_storeObject` 的 `_knownObjectValid` 同样对小对象强制完整校验。
**P0-1b（不盲信索引）**：命中仍校验账号命名空间 / 存在 / 精确大小 / `verified_at`，任一不符即失效索引行并回退 legacy。
**P1（配额隔离）**：`MediaQuotaPolicy` = 账号软配额 **384 MiB**（沿用线上值）+ 设备硬上限 **1024 MiB**
（集中常量；若设备上限仍是 512MiB，两个账号各 384MiB 会互相驱逐 = 没修 P1）；淘汰只在账号内进行，设备上限兜底。
**索引体系**：LRU touch **批量去抖**（内存 pending，`maxPendingTouches=32` / `touchDebounce=60s` / 显式 flush，
滚动不产生逐次落盘）+ 热 LRU 512；`MediaGarbageCollector.collectGarbage`（引用数**从 `refs/*.ref` 重算**，不依赖计数器）
+ **pin/lease**（`pinPath`/`unpinPath`，视频全屏播放接线 `room_page._openVideoViewer`，播放中不被配额/GC 删）；
崩溃双向恢复；**失败降级**（索引打不开 → 纯 legacy，30s 重试）；`MediaCacheMetrics`（`cache_lookup_ms` /
`index_lookup_ms` / `hash_bytes_read` / `disk_bytes_read` / `disk_bytes_written` / `eviction_ms` / `gc_ms`，
**计数器无条件累加**，**无 PII**：账号/引用均 sha256 摘要入库，测试直接扫描 db 文件断言无明文房间/事件/账号 ID）。
**生命周期统一**：相册视频首帧并入对象库（`roomId='device-gallery'`，删除独立无配额目录的使用）；
Moments 已经共用对象库 → **自动受益**，HTTP/TTL 层不动；Avatar **明确不改**（只由 `flutter_cache_manager`
承载，不存在重复落盘；再交给 `MediaCache` 会变两份落盘，真正统一需搬迁 etag/validTill 并改刷新语义 = 禁止 → Phase 3）；
`SentVideoLocalRegistry` **仍只报告**（压缩产物被 `prepareLocalChatVideo` 的 finally 删除）。
**未删除任何既有缓存、未清空应用数据、未新增依赖**（复用既有 `sqflite_common_ffi`），目录保持
`chat-media/v2/<sha256(account)>`（**已**账号隔离，不做机械迁移），旧对象首次访问时惰性校验并回填索引。
门禁：`flutter analyze` **No issues found**；新增 25 条 Phase 2 测试（`media_index_phase2_test.dart`，含 500MB 稀疏对象
命中 0 哈希字节、小对象仍完整校验且同尺寸篡改必被发现、账号隔离、LRU、pin/GC、崩溃恢复、并发、无 PII）；
相关集 75 通过；**全量 `flutter test --timeout 120s` 3120 通过 / 0 失败（退出码 0）**
（前两次全量各出现 1 条**与本改动无关**的既有实时定时器/调度敏感用例在并行负载下抖动
——`call_alerts_test.dart` 与 `account_client_selection_test.dart`，均单独重跑通过，第三次全量干净）；
frontend `npm test` **209 通过**；`py -3.12 scripts/verify_ui_contract.py` **PASS (31 components, 369 screens)**；
`py -3.12 -m pytest tests/mobile -q` **70 通过**；`scripts/verify.ps1` **`Verification: PASS`（退出码 0）**。
UI 交付说明：本次是**非视觉**的缓存/索引行为变更（气泡、视频卡片外观、占位底、时长角标未变），
聊天视频卡片从未纳入 HTML demo → 无 demo/registry 改动；**Figma 已退役**。进入
[任务记录](tasks/2026-09-17-media-engine-phase2-local-index.md)、
[Phase 2 报告](../verification/2026-09-17-media-engine-phase2-local-index.md) 或
[Phase 2 设计与落地说明](../architecture/media-engine-phase2-local-index.md)。

## 2026-09-17 Media Engine Phase 0（设计）+ Phase 1（视频加载优化）（本地完成，**未构建/未真机/未部署/未 push**）

用户两阶段任务：**Phase 0** 建立下一代媒体基础设施方向（**只设计**）+ **Phase 1** 实际编码解决视频加载问题。
**Phase 0**：新增 `docs/architecture/media-engine-v1.md`——当前链路（聊天图片/聊天视频/朋友圈媒体，
标注压缩点、缩略图生成点、缓存位置与生命周期；朋友圈**部分共享**缓存：解密对象库与内存预算共享、
HTTP CacheManager 与键/TTL 独立、演绎版参数不同故内容寻址也命中不了）、目标
`MediaService`（Chat/Moments/Avatar/Group-File 消费者 + 两个 MediaGateway 出口）、
核心模型 `MediaObject`/`MediaVariant`（图片 original/thumbnail_small/thumbnail_medium/preview；
视频 poster/preview_video/compressed_video/original_video）/`MediaReference`（引用计数与引用式回收）、
与现状的差距表、**明确不做远端去重**（需后端配合；本阶段不改服务端存储/上传协议/加密协议）、
Phase 2+ 迁移顺序与不变量。
**Phase 1（已编码）**：根因 = `RoomPage._loadVideoPoster` 在「事件无可用缩略图」时用
`resolveCachedVideoFile` **下载+解密整段视频**只为抽一帧封面，且触发点是无门控的
`VideoMessageCard.initState`。修复：新增 `VideoPosterPipeline`（**构造参数里没有任何下载入口**，
因此「为封面下载完整视频」在类型层面不可能发生，并有源码级防回归测试；优先级 =
会话内存 LRU → 会话磁盘 → 本机持久封面缓存 → 服务端 poster 缩略图附件（≤480px）→
**本地抽帧（仅当本地已存在视频文件）** → 占位），新增 `VideoPosterDiagnostics`（白名单字段 +
加盐哈希 ID + 失败安全），`MediaVisibility` 新增 `warmExtent`（±buffer）与三态
`MediaVisibilityWindow`（默认 0 时与原实现逐字一致），`VideoMessageCard` 改为**可见性门控**
（`kVideoPosterWarmRows = 5` ≈ ±790pt：进入窗口才请求封面，路由被覆盖/退后台不请求）+
`posterRevision`（视频播放后本地已有文件 → 补生成 → 缓存与 UI 更新），`MediaCache` 新增
`probeCachedObject`（廉价存在性探测，**不重算大文件哈希**；完整性读取仍走 `cached`），
`video_poster_extractor` 新增可选 `onFrameDecoded` 诊断回调（默认行为不变，含发送侧 `0ms` 语义）。
缓存：**没有新建第二套系统**——内存/会话磁盘复用 `VideoPosterSessionCache` + `VideoPosterDiskStore`
（原样保留），持久层复用 `MediaCache` 账号命名空间对象库（`chat-media/v2/<sha256(account)>` +
内容寻址 + 384/512MiB mtime LRU），元数据映射（`poster_id`=对象名、`size`=`.len`、
`last_access`=mtime、`media_id`=`refs/<sha256([roomId, '<eventId>#video-poster-v1'])>`）。
`SentVideoLocalRegistry` **审计确认**（登记的是相册原片而非压缩产物；压缩产物被
`prepareLocalChatVideo` 的 finally 主动删除，强改需动 outgoing 产物所有权）→ **按要求只报告不强改**。
门禁：`flutter analyze` **0 issue**；新增 24 条测试（19 流水线 + 5 可见性，含 500MB 不下载、
100 条视频快速滚动不全量处理、账号隔离、缓存命中、脱敏日志）；要求范围 `test/features/matrix`
+`test/features/moments`+`test/performance` **1718 通过**；`test/ui/chat` 等 **250 通过**；
全量 `flutter test` **3094 通过 / 0 失败（退出码 0）**。UI 交付说明：本次是**非视觉**的加载行为变更
（视频卡片外观/占位底/时长角标未变），且聊天视频卡片从未纳入 HTML demo（registry 与
`frontend/src/components` 无视频组件）→ 无 demo/registry 改动，`verify_ui_contract.py` 保持 PASS；
**Figma 已退役**。进入
[任务记录](tasks/2026-09-17-media-engine-v1-phase1.md)、
[Phase 0-1 报告](../verification/2026-09-17-media-engine-v1-phase1.md) 或
[Media Engine v1 设计](../architecture/media-engine-v1.md)。

## 2026-09-17 媒体架构审计 + 引用消息跨距离修复 + 相册大图编辑/裁剪重做（本地完成，**未构建/未真机/未部署/未 push**）

用户一条消息三项：① 媒体缓存/加载/存储架构**审计**（明确「本阶段只输出报告+方案+P0/P1/P2，不要一次重构 Media Engine」）；
② 引用消息「距离过远永久显示原消息加载中」；③ 相册查看大图增加「编辑」，裁剪交互做到**微信级**。
**① 审计**：新增 `docs/verification/2026-09-17-media-architecture-audit.md`（330 行）：图片链路
（压缩点 = photo_manager `thumbnailDataWithSize(1280,80)`；缩略图 = `buildChatImageThumbnail` ≤800px/≤100KB；
正文+缩略图两份上传）、视频链路（**封面缺失时为封面下载整段视频**、无渐进播放、磁盘 384/512MiB LRU 配额）、
四层缓存表、去重现状（本地 `sha256(bytes)` 对象库跨房间合并；远端聊天走 SDK `sendFileEvent`、朋友圈走业务 API，
**零远端去重 → 同一文件 ≥3 次上传**；确定性加密使服务端内容寻址在协议上可行，是否真去重**未确认**）、
目标 `MediaService` 门面与迁移顺序、P0-1（磁盘命中全量重算 SHA-256）/P0-2（封面兜底整文件下载）/P0-3（跨域三份上传）
与 P1-1..P1-5、P2-1..6 清单及「未确认」附录。**② 引用修复**：新增五态
（`loading/loaded/notFound/permissionDenied/networkError`）+ `ReplyMessageResolver`（**单飞、3 秒超时、终局缓存、
只把 Exception 归类成可重试失败、Error 继续抛**）+ 可选能力 `RoomMessageLookupSource`（SDK `Timeline.getEventById`：
本地加密库 → 服务器单事件查询 + 解密，**一次往返**恢复 1000 条以前的引用，而不是逐页翻历史）+ 仅内存、按账号+房间
隔离的 `MessageTimelineCache`（不落盘：明文只允许在内存与 SDK 加密库中）+ 公共组件 `QuotePreviewCard`
（保留 `reply-preview-<id>` 键）；行缓存 key 纳入解析状态，状态变化必定重建；清空聊天记录时丢弃投影。
**③ 相册编辑**：大图底部改为 **编辑 → 选择 → 闪照** 三枚同风格胶囊（键名不变），编辑取**原图字节**进入
`WeChatImageEditorPage`，导出后以 `editedGalleryPhoto(bytes)` 作为**新的媒体对象**返回选择器（原图不被覆盖）；
裁剪重做为微信级：画布占满编辑区 + `BoxFit.contain` 映射、**裁剪框默认覆盖整张图片**、四边四角 8 控制点拖动
（`image_crop_geometry.dart` 纯函数，角优先命中、最小 56、夹在图片内）、60% 半透明遮罩 + 亮边框 + 三分线 +
拖动中控制点高亮、双指以焦点为锚缩放（1–8）+ 单指平移、比例预设（自由/1:1/4:5/16:9）、旋转 90°（裁剪框与标注一起
映射到新文档空间）、**还原**（原始图片状态/默认裁剪框/缩放/旋转）与**应用裁剪**（`ImageEditorActionButton`：等高 44、
同圆角 8、同 12pt 间距，应用裁剪品牌色填充 + 按压高亮）。UI 按 `ui-demo-delivery` 同步 HTML demo
（`frontend/src/components/image-editor.js` + `components.css`，screen id `chat/image-editor`，registry 补 `onSend`/`crop-reset`）；
**Figma 已退役**。门禁：`flutter analyze` **0 issue**；新增 4 个测试文件 **48 通过**；引用链回归 **1576 通过**；
全量 `flutter test` **3070 通过 / 0 失败（退出码 0）**；`verify_ui_contract.py` **PASS (31/369)**；frontend `npm test` **209 通过**；
`scripts/verify.ps1` **`Verification: PASS`**（退出码 0）。
**有意偏离（已记录）**：未把解析结果写回 SDK 事件库——SDK 只有 `storeEventUpdate`（timeline 插到最新/ history 追加到末尾），
会破坏本地 timeline 顺序且无安全 upsert API；改为「SDK 本地加密库优先读 + 进程级缓存」并把此偏离写入报告 R1。
**未构建/未真机/未部署/未 push**（用户明确本次不需要）。进入
[任务记录](tasks/2026-09-17-media-quote-image-editor.md) 或
[完整报告（含 10 节：审计/问题/引用方案/相册编辑/修改文件/新增测试/analyze/test/性能变化/剩余风险）](../verification/2026-09-17-media-quote-image-editor.md)。

## 2026-09-17 CI 并发测试失败修复：Matrix 测试存储目录按进程隔离（`0a9e46a3`）

用户报告 `android-ci.yml`（L91-94）Flutter 测试步骤 `3018 通过 / 1 失败`，失败为
`synthetic credential write failure`，`Causing statement: INSERT OR REPLACE INTO box_client (k, v)`。
根因确认：`test/features/matrix/matrix_client_factory_test.dart` 的 `MatrixTestPaths` 返回**仓库内同一个
固定绝对路径**（`…/conversation-state-main/matrix-cache-tests`），而它被
`matrix_client_factory_test.dart` 与 `conversation_optimistic_state_test.dart` 两个套件共用；
`flutter test` 默认并发跑测试文件（每文件独立进程），于是两个进程同时打开并写同一个 SQLCipher 库，
`box_client.token` 写入撞车 → **非确定性的单例失败**。
排查结论：并非「目录不存在」（实测删掉该目录后 SDK 会自建并全部通过），也**不是**头像/Matrix 用例的
stderr 诊断输出；全套件仅这一处是**跨进程共享的固定路径**（其余同类 fake 都在 `setUp` 里用
`createTemp`+`tearDown` 或临时子目录隔离，例如 `media_cache_clear_test`、`video_playback_extension_test`）。
修复：目录改为**进程私有**（`Directory.systemTemp.createTempSync('starchat-matrix-tests-$pid-')`），
**进程内保持一致**（多处测试专门验证跨 factory/client 实例持久化，故不能每用例换目录）。
新增两条回归测试：目录必须含 `pid` 且**不在仓库目录内**、同进程内两次调用必须相同；
变异探针：把实现复原为旧的共享路径 → 新测试立即转红（`contains '14532'` 失败）。
另验证修复后**不再重建仓库内 `matrix-cache-tests` 目录**（测试写入只落系统临时目录）。
**未采用** `flutter test --concurrency=1`：那只是掩盖共享数据库竞态，非修复（用户亦如此要求）。
门禁：`flutter analyze` 无问题、定向 80 通过、全量 **3021 通过 / 0 失败**；已 push（`0a9e46a3`）。
**限制**：本仓库为私有仓库，本工作流无法读取 CI 结论（GitHub API 403 需鉴权），
「CI 转绿」需在下一次 CI 运行后由 CI 证据确认。

## 2026-09-17 Android 0.3.95/2132 更新弹窗（**已上线**；先被 SSH 阻断，恢复后一键续做完成）

用户要求「推送 Android 版更新弹窗」，确认候选 = `82b24ba7`（含闪照 route-exit fail-open 修复、
tombstone 生命周期接线、真实外设音频路由、TURN 措辞与搜索回填边界，以及 `ad12f92c` 红包弹窗恢复）、
版本 = **0.3.95 + 2132**、**不强制更新**（`min_supported_build` 沿用线上值）、发布后 push GitHub。
候选 commit **`9fa2c963`**（pubspec/app_config 递增；构建前后工作树 0 项改动）。门禁：`flutter analyze`
无问题、全量 `flutter test --timeout 120s` **3019 通过 / 0 失败**、`test_app_build_contract.py` 2 通过。
APK 按固定流程（ARM64 release + 三项 HTTPS dart-define → Apktool 2.12.1 → zipalign 36.0.0 `-P 16 -f 4`
→ 固定身份 `75b31c66…ba61fff`）构建：aapt 身份 2132/0.3.95/arm64，v2+v3 签名，zipalign 通过，
语义核对 **25346/25346 类**、**338 项原生资产零变化**、`manifest.diff` 0 字节；SHA256
**`35CA0962E9DDB3655474B2BCC5182DFCEB52D57549020C8680FC2E4BE3374633`**（79,801,374 字节）。
GitHub：`b8a7040c..9fa2c963`，`origin/main...main` = `0 0`。
**阻塞已解除并完成发布**：跳板机 SSH 于第 3 轮恢复（`ssh jumper` exit=0）；先重读生产基线
（`latest-arm64.apk -> …2129`，容器 healthy、未重启），再执行
`release-2132/publish-all-2132.ps1`：分块上传 → 服务端合并 SHA 门 → `install -m 0644`
不可变文件 `ChatFlow-0.3.95-build2132-arm64.apk` → `latest-arm64.apk` 原子切换 → 弹窗
`inspect/apply`（**5 条审计**、`min_supported_build` 仍 **3**、iOS 行未改）→ 带 token 的真实 HTTP
投影 **`0.3.95/2132`** → 双侧公网验证（新包 200/206 + MIME、`latest` 指向新包、旧包 2129 仍 200、
未授权 401、**公网整包 SHA 与候选一致**，服务器与工作站双侧）。回退：
`publish_settings_2132.py rollback` + `ln -sfn ChatFlow-0.3.94-build2129-arm64.apk latest-arm64.apk`。
注意：更新文案（并发工作流撰写）只写闪照/通话/搜索，未逐条点名红包与钱包改动（需要可补发一条 notes 更新）。
进入[发布记录（含阻断、脚本修复与执行全程）](../verification/2026-09-17-android-0395-2132-publish-attempt.md)
或[构建与门禁记录](../verification/2026-09-17-android-0395-2132-release.md)。

## 2026-09-17 第二轮五项 UI/交互（红包整页 / 邀请码 / 钱包复制位置 / 充值页 / 提现按钮）（本地完成，**未构建/未部署**）

用户五项：①点红包封面**保持原本的居中磨砂弹窗**（用户复盘否决了初版的「整页红包页」，已整体回退），
重点改为**领取成功后响开启音并直接进入「领取详情」页**——`RedPacketClaimDialog._claim()` 成功后
`play(redpacketOpen)` → `onClaimed` → `_openClaimRecords()`（关弹窗 + push 详情），
`FinanceMessageEntry` 路由恢复原状；
②邀请码页删除「复制邀请链接」磁贴（保留复制邀请码）；③钱包卡片的地址复制 icon 原挂在「当前点钻余额」行，
现移入地址同一 `Row`；④充值页删除「点钻与 USDT 兑换」卡片（组件已无入口，连同其组件级测试一并删除，
服务端接口与 `conversionEnabled` 能力位保留）；⑤提现页「取消提现申请」改为**红色填充**（新增 token
`WeChatColors.dangerFill = 0xFFFA5151`，取值即设计规范 `--color-danger` #fa5151），
无背景色的动作按钮（「全部提现」「开始新的提现」「重新填写金额」等）统一改为带边框的
新注册组件 `WeChatSecondaryButton`（tone neutral|danger）。门禁：红 9 失败（各自原因均符合预期）→ 定向
**172 通过**、`flutter analyze` 无问题、全量 `flutter test` **2852 通过 / 0 失败**、
`verify_ui_contract.py` **PASS（31 components, 369 screens）**、frontend `npm test` **209 通过**。
UI 交付按 `ui-demo-delivery`：registry 新增 `secondary-button` 组件 + tokenParity `--color-danger` ↔ `dangerFill`，
demo 更新 `frontend/src/screens/wallet-binding.js`（地址旁复制按钮、红色取消按钮）与
`frontend/src/styles/primitives.css`；**Figma 已退役**，仅更新 HTML demo。
随后按固定流程构建 **debug 0.3.94-debug/2131**（源码 commit `ad12f92c`，**从干净冻结工作树构建**，
交付包 SHA256 `9B4C40D5…D1AFA3`）并保留数据覆盖安装到 Mi 6（`firstInstallTime` 未变，设备回读 `base.apk` SHA
与固定证书 `75b31c66…ba61fff` 一致）。**注意**：交付时主工作树存在另一条工作流的 41 项未提交改动
（call/search/voip/flash_photo 等，非本任务），故用 `git worktree add --detach` 隔离构建，避免把它方半成品打进包；
他方改动全程未被触碰。未推送（`ad12f92c` 及本文档提交待在用户指示后 push）。
**注意**：本机 git 走 `http.proxy=127.0.0.1:7897` + `http.sslBackend=schannel` 时 push 会报
`schannel: failed to receive handshake`（只读 `ls-remote` 正常）；用
`git -c http.sslBackend=openssl push origin main` 可成功（未持久化改配置）。
进入[任务记录](tasks/2026-09-17-ui-round2-five-fixes.md)或
[验证记录](../verification/2026-09-17-ui-round2-five-fixes.md)。

## 2026-09-17 「清空聊天记录」会话位置修复 + Android 0.3.94/2129 发布 + GitHub 推送（**已上线并推送**）

用户三项：①清空聊天记录后会话不再掉到消息列表末尾；②推送 Android 最新版更新弹窗；③推送到 GitHub。
①根因：排序锚点取 `room.lastEvent?.originServerTs ?? epoch0`，清空本机历史后事件被 `isEventHidden` 隐藏
→ `lastEvent` 为 null → 锚点落到 1970-01-01 → 掉到末尾。修复：新增顶层
`conversationSortAnchor(room)`（`lastEvent?.originServerTs ?? lastActivityAt ?? epoch0`），
`MatrixConversationRoomSnapshot` 新增可选 `lastActivityAt`（由 `_snapshotRoom` 从事件时间戳填充，与隐藏解耦），
`_snapshotRoom` 排序锚点改用它；变异探针（忽略 `lastActivityAt` → 实得 1970-01-01）转红后复原。
定向回归 8 通过 / 0 失败，`flutter analyze` 无问题，commit `175b3e6e`。
②候选冻结 `c73c12fb`（`0.3.94+2129`，全量 `flutter test` **2852 通过 / 0 失败**），按固定流程构建
（ARM64 release + 三项 HTTPS dart-define → Apktool 2.12.1 → zipalign 36.0.0 `-P 16 -f 4` → 固定身份 `75b31c66…`），
aapt 身份 2129/0.3.94/arm64，v2+v3 签名，zipalign `Verification successful`，语义核对 25345/25345 类、
338 项原生资产零变化、`manifest.diff` 0 字节；SHA256
**`B3B70C665E524CE95807EC0D80CA7BF0F211B242176285ED2D8F67CCABB4BF92`**（79,408,158 字节）。
16MiB 分块上传 + 服务端合并 SHA 门 + `install -m 0644` 不可变文件，`latest-arm64.apk` 原子切换至 2129，
2127 保留（回退）。更新弹窗 trace `android-release-0.3.94-2129-20260917`（5 条审计，min `3` 沿用，iOS 行未改），
并以**真实会话 token 的 HTTP GET** 验证 `/app-updates/latest?platform=android`：未授权 401、带 token 200 且
`0.3.94/2129`；服务器+工作站双侧公网 200/206 + MIME，**公网整包 SHA256 与本地构建包一致**。
③`git push origin main` → `5d43ce34..c73c12fb`，`origin/main...main` = `0 0`。
全仓门禁 `scripts/verify.ps1` 于 `ebd56b36` **`Verification: PASS`**（Business API/Worker 1933 通过 / 58 跳过、
Flutter boundary 70、UI contract、AST parse 219、Alembic/OpenAPI/Compose render 全通过）。
**注意（本次踩到的假阳性）**：`www.liuhetong888.com` 对未知路径回落 SPA（`200 text/html`），
对 `www` 探测 `/api/...` 或 `/health/...` 不能当作 API 存活证据；客户端实际用 non-www
`https://liuhetong888.com`，健康路径为 `/api/v1/health/{live,ready}`。进入
[任务记录](tasks/2026-09-17-clear-history-order-android-2129-release.md)或
[发布与验证记录](../verification/2026-09-17-clear-history-order-android-2129-release.md)。

## 2026-09-17 生产部署：红包手续费 0.5% + 迁移 0068_red_packet_fee（**已上线**）

用户指令「直接部署迁移 0068 与扣费」（覆盖此前"新客户端先行"次序）。按 admin 流程：候选镜像基于在线镜像最小覆盖
（API `16522404…` → `starchat-business-api:redpacket-fee-20260917` = `48948fb7…`；worker `b5bd6973…` →
`starchat-business-worker:redpacket-fee-20260917` = `f9d03982…`；worker 的 `service.py` 与其仓库 HEAD 有 +81/−9
无关历史差异，按 ADR-0071 r2 教训**外科合并 +14/−2**，只加 `_refund` 手续费退款与 `skip_coverage`）→
一次性 PG16 演练（0001→0068 全链、`REHEARSAL_OK`、`downgrade 0067` 列消失）→ `pg_dump -Fc` 备份
（`824cc984…`，0600）→ **先迁移后切码**（迁移 expand-only，旧代码在迁移后仍健康）→ 切换 API 与 worker。
切换后验证：env 61/65、挂载与 `127.0.0.1:8082` 不变，部署文件与 payload 逐一相同，真实运行时导入含
`red_packet_fee`/`fee_refund`，live head `0068_red_packet_fee`，52 行历史红包 `fee=0.00`（退款口径不变），
服务器+工作站双侧健康 200 / 未授权 401 通过，仅两个业务容器重建、无 traceback。
**兼容性（已告知并接受）**：线上 ≤0.3.93/2127 客户端不展示手续费且按 `total` 校余额，余额处于 `[total,total+fee)`
时会收到带合计说明的 422；建议尽快把含手续费展示的客户端作为正式版发布（2128 debug 已在 Mi 6）。进入
[部署记录](../verification/2026-09-17-redpacket-fee-production-deployment.md)或 [ADR-0073](../adr/0073-red-packet-fee.md)。

## 2026-09-17 钱包绑定/刷新/告警修复 + 红包手续费 ADR-0073 + 充值提现美化（本地完成，**未部署/未真机**）

用户报五项：①绑定页输入已被他人登记的钱包地址后**无法删除且一直提示**（根因：`registerAddress()` 先持久化登记草稿，
终局失败后从不清理，而地址框启用条件是 `bindingOp == null` → 被拒地址永久锁死；「重新填写」只对签名方式显示）；
②每次进钱包闪一下「功能状态暂不可用」（根因：`refresh()` 每次先清零能力状态，成功才置 true）；
③刷新按钮应进顶部导航栏右侧；④红包加手续费；⑤充值/提现美化（先 demo）。修复：终局失败集合 → 清草稿 + 释放输入框 +
文案改为「请更换一个属于你的钱包地址」，地址框只在拿到服务端 `id` 后锁定，「更改绑定」按钮带文字并展示 30 天限制
（冷却期先解释再禁用）；`capabilitiesUnavailable` 仅「从未可知且失败」为真、刷新期间沿用上次已知能力；`WalletPage`
改为非嵌入自持导航栏（`trailing: refreshControl()`），AppHome 去掉重复 scaffold；充值/提现按已通过的
`frontend/design-demo/wallet-deposit-withdraw-redesign-demo.html` 落地 `stepIndicator`/`statusHero`/`rowsCard`。
**红包手续费（受保护变更，ADR-0073 已批准）**：0.5%、最低 0.01 点钻、与转账同构，创建
`{sender: -(total+fee), escrow: total, PLATFORM_FEE: fee}`，未领完退款时手续费随未领取本金退回；`RedPacket.fee`
持久化 + 迁移 `0068_red_packet_fee`（expand-only）；创建响应与「仅发起方可见」的 detail 暴露 `fee`；客户端展示
手续费与实扣合计并按 `total+fee` 校验余额。门禁：后端定向 **71 通过**、Flutter 钱包 **75 通过**、红包客户端
**62 通过**、全量 `flutter test` **2848 通过 / 0 失败**、`flutter analyze` 无问题、UI 契约 `PASS`。
**后续进展（更新本条的过时状态）**：用户当日改令「直接部署迁移 0068 与扣费」，API 手续费与迁移 0068
已于 2026-09-17 15:53 +08 上线（见本文件顶部部署条目）；含手续费展示的正式客户端 **0.3.94/2129 同日发布**，
该「新客户端先行」限制随之解除。进入
[任务记录](tasks/2026-09-17-wallet-redpacket-five-items.md)、
[验证记录与领域/质量安全自审](../verification/2026-09-17-wallet-redpacket-five-items.md)或
[ADR-0073](../adr/0073-red-packet-fee.md)。

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


