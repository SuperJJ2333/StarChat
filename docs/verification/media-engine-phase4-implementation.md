# ChatFlow Media Engine Phase 4 实施报告（Full Implementation）

- **日期**：2026-09-18（Asia/Hong_Kong，实施横跨 2026-09-17/18 夜）
- **仓库**：`SuperJJ2333/StarChat`（分支 `main`，起点 `afe70a1c`）
- **范围**：Media Engine **Phase 4 Full Implementation**（服务端 Media Platform）
- **架构依据**：[Phase 3.1 冻结文档](../architecture/media-engine-phase3-freeze.md)（ADR-001…ADR-006）、
  [Phase 3 设计](../architecture/media-engine-phase3-server-design.md)、
  [Phase 3 审计](../architecture/media-engine-phase3-server-audit.md)
- **提交**（5 个可构建提交，按任务书要求拆分）：
  `bf397700` domain core → `88a6b0c7` gateway → `850935e7` reference lifecycle →
  `e8284bbb` authorization → `dfbcf4f6` moments integration
- **未做**：Avatar 接入（明确延期）、全球去重、E2EE 服务端处理（解密/转码/生成变体）、
  修改 Matrix Server/协议、修改 Moments API 语义、构建 APK/IPA、真机、部署。

---

## 1. 实现范围

### 1.1 交付对照（任务书 §四 的 7 个子阶段）

| 子阶段 | 交付 | 主要文件 |
| --- | --- | --- |
| **4.1 Media Domain Core** | `MediaObject` / `MediaBlob` / `MediaVariant` + 三种 `digest_kind` + 隔离域 + 策略 + 存储 + 指标 + expand-only 迁移（7 张新表） | `app/modules/media/{domain,policy,models,storage,metrics,repository}.py`、`migrations/versions/0069_media_platform.py` |
| **4.2 Media Gateway** | `MediaGateway`（`resolve` / `authorize` / `resolve_variant`）、`BusinessMediaGateway`、`MatrixMediaGateway`（只读 + 授权委派）、Variant Resolver、Upload Engine 接口、HTTP 面、main 接线 | `{gateway,variants,authorization,upload_engine,service}.py`、`app/api/media_platform.py` |
| **4.3 Media Reference System** | 引用模型（含 `permission_scope`/`ref_kind`/`state`）、幂等 attach/release、按业务对象释放、引用计数重算 | `references.py` |
| **4.4 Authorization Layer** | `AccessGrant`、`GrantAuthorizer`（fail-closed）、Signed URL（HMAC，服务端 TTL，subject 绑定，版本撤销）、audience/private 分级 | `grants.py`、`signed_urls.py`、`authorization.py` |
| **4.5 Variant Resolver** | 按网络/设备偏好/权限范围/内容类型排序 ready-only 候选 | `variants.py` |
| **4.6 Lifecycle / GC** | 4 状态机 + 正交 `QUARANTINED`/`PINNED`；`MediaGarbageCollector`（dry-run / audit / recovery / E2EE 下限） | `lifecycle.py` |
| **4.7 Moments Integration** | 新上传路径 `Moments → MediaGateway → MediaObject`，旧路径与旧数据零改动可读 | `moments_bridge.py`、`app/api/media_platform.py` |

### 1.2 明确未做（及理由）

| 未做项 | 理由（冻结依据） |
| --- | --- |
| Avatar 迁入平台 | ADR-004 §4.4.4 / DEFERRED-4：与头像 TTL/版本/高频刷新语义冲突，收益≈0 |
| 全球明文去重 / 跨用户明文复用 | ADR-001：拒绝 Option C；策略层显式 `raise` 拒绝开启 |
| E2EE 服务端解密 / 转码 / 生成变体 | ADR-004 §4.4.5：服务器无明文无密钥；E2EE 变体只能发送端产出 |
| Matrix 媒体字节迁移 / 重加密 / 重写事件 | ADR-004 §4.4.1：永不迁移字节，`mxc://` 永久可读 |
| 分片上传的实际传输 | ADR-005 与任务书 §10：本阶段只实现接口（`501` + 能力字段），传输在后续阶段 |
| CDN 与对象存储 | Phase 3 后半（DEFERRED-12） |
| Flutter 客户端改造 | 本阶段为服务端实现；客户端接入属下一阶段（含 1GB+ 分片上传） |

### 1.3 代码量

| 类别 | 文件 | 行数（新增） |
| --- | --- | --- |
| 领域与基础设施 | 6 | ~1 780 |
| 网关/授权/生命周期 | 7 | ~1 900 |
| HTTP 面 + 接线 + 配置 | 3 | ~700 |
| 迁移 | 1 | 297 |
| 测试 | 5 个文件 | ~2 360（**71 条新测试**） |

---

## 2. 架构变化

### 2.1 新旧并存（Strangler）

```
                    ┌──────────────── Media Platform v1（本次新增） ────────────────┐
                    │  MediaGateway: resolve / authorize / resolve_variant         │
                    │  Object(逻辑) ─ Variant(演绎版) ─ Blob(字节+摘要+信封)        │
                    │  Reference(业务引用) · Grant(授权) · Signed URL(交付)        │
                    │  Lifecycle(4 态) · GC(dry-run/audit/recovery) · Metrics       │
                    └───────┬───────────────────────────────┬─────────────────────┘
                            │                               │
              BusinessMediaGateway                  MatrixMediaGateway
              （明文域：Moments / 文件 / 未来）        （只读：mxc:// 解析 + 授权委派）
                            │                               │
                    平台对象存储（新键空间）             既有 Matrix 媒体库（**不动**）
                    moments/media/user/<hash>/…           data/synapse/media_store
                            │                               │
                    ┌───────┴───────────────┐               │
                    │ 既有私有对象目录       │◀── 同一目录 ──┘（不是第二套存储/缓存）
                    └───────────────────────┘
```

### 2.2 关键结构决定

| 决定 | 内容 | 影响 |
| --- | --- | --- |
| **三层拆分** | 权限/引用只挂 `MediaObject`；摘要/隔离域只挂 `MediaBlob`；编码元数据与就绪态挂 `MediaVariant` | 变体级复用、按对象计引用、字节层去重互不干扰 |
| **摘要三元身份** | `(digest_kind, digest_version, envelope_version, digest)`，跨类比较直接抛异常 | "明文 hash == 密文 hash" 在类型层不可能发生 |
| **隔离域地址** | 键内含 `media/{user|e2ee|public}/<scope-hash>/…`，域名与 scope 必须成对出现 | 明文/密文写错命名空间会立刻失败 |
| **E2EE 不建平台对象** | Matrix 附件只解析 + 委派授权，不复制不重加密不伪造身份 | 旧消息无需迁移；E2EE 边界不扩大 |
| **Moments 桥** | 平台负责字节，既有 `moment_media_uploads` 只增加一行记账指向平台键 | 零改动既有 Moments 代码即获得新上传路径 |
| **新增而非替换** | 迁移 0069 只建 7 张新表；未改任何既有表/列/约束 | 可在线执行；回退=停用新端点 |

### 2.3 新增 7 张表（expand-only）

`media_objects`、`media_blobs`、`media_variants`、`media_references`、`media_access_grants`、
`media_upload_sessions`、`media_gc_runs`。

其中三个**部分唯一索引**承载冻结语义：

```sql
-- 只有"可复用"的对象占用摘要槽（随机信封、跨用户明文因此不会互相阻塞）
CREATE UNIQUE INDEX uq_media_objects_digest_slot ON media_objects
  (owner_scope, digest_kind, digest_version, envelope_version, content_digest)
  WHERE dedup_eligible AND status <> 'DELETED';
-- 只有 active 引用唯一，released 行留作审计且可重新挂载
CREATE UNIQUE INDEX uq_media_references_active ON media_references
  (media_id, business_type, business_id) WHERE state = 'active';
-- 只有未撤销的授权唯一
CREATE UNIQUE INDEX uq_media_access_grants_subject ON media_access_grants
  (media_id, subject_type, subject_id, permission) WHERE revoked_at IS NULL;
```

---

## 3. ADR 遵守情况

| ADR | 要求 | 实现证据 | 结论 |
| --- | --- | --- | --- |
| **ADR-001 Isolation** | 明文域用户空间隔离；密文域保持受限复用；禁止全球明文去重 | `domain.owner_scope_key/assert_object_domain`；`repository._find_blob` 明文按 `owner_scope` 过滤、密文要求 `dedup_eligible`；`policy.MediaDedupPolicy.decide` 对 `allow_cross_user_plaintext=True` 直接 `raise IsolationViolation` | ✅ |
| **ADR-002 Digest** | 三种摘要各自明确归属；禁止互相比较；禁止客户端存在性查询 | `Digest.__eq__` 跨类抛 `CrossKindDigestComparison`；`_authoritative_digest` 拒绝 TRANSPORT 作身份；`assert_transport_claim_matches` 只校验；全局无"按摘要查询"端点 | ✅ |
| **ADR-003 Authorization** | 五段读取流程；Signed URL 绑定 media_id/subject/expire/signature/variant；TTL 服务端决定；private 禁转发、audience 允许且有 TTL | `service.read_variant`/`read_via_signed_token` 走授权→解析→选档→交付；`signed_urls.MediaSignedUrlCodec` 令牌含 `m/k/s/a/p/t/e/j/g/gv/su`；API 无 `expires_in` 参数（测试断言客户端传 `expires_in` 被 422 拒绝）；private 校验 `subject == caller` | ✅ |
| **ADR-004 Matrix Compatibility** | 禁止迁移字节；`MatrixMediaGateway`；双读/惰性/不双写 | `MatrixMediaGateway` 只解析 + `DELEGATED`；测试断言 legacy 解析后 `MediaObject/MediaBlob` 计数为 0；`BusinessMediaGateway.resolve` 对 `media://`/能力 URL 返回 `read_old_only` | ✅ |
| **ADR-005 Upload Boundary** | Upload Engine 独立；不得把上传/对象/消息发送混成一体 | 独立 `MediaUploadEngine` + 会话表；`/media/platform/uploads*` 只做会话/续传/abort；分片与 commit 返回 `501 MEDIA_UPLOAD_NOT_IMPLEMENTED` 并在响应中声明 `chunk_upload_supported=false` | ✅ |
| **ADR-006 Lifecycle** | 删除=解引用；4 状态；pin/quarantine 正交；GC 可 dry-run/审计/恢复 | `references.release*` → `_recount_in_session` → `ORPHAN`；`lifecycle.MediaGarbageCollector` 支持 dry_run/enforce、写 `media_gc_runs`、恢复 `DELETING`、E2EE 下限、pin/quarantine 保护 | ✅ |

补充冻结项：架构原则 P1–P10 中与实现直接相关的 P1（E2EE 边界）、P2（只信服务端摘要）、P3（元数据可重建）、
P5（fail-closed）、P7（开关可关）、P8（不透明 ID）、P9（旧数据永远可读）均有对应实现与测试。

---

## 4. 新增模型

```python
MediaObject   : media_id, owner_id, owner_scope, isolation_domain, origin_domain, kind,
                canonical_mime/size, width/height/duration_ms,
                digest_kind/digest_version/content_digest, envelope_mode/version,
                dedup_eligible, status(ACTIVE|ORPHAN|DELETING|DELETED),
                visibility_hint(private|audience|public), ref_count, metadata,
                pinned_until, quarantined_at/reason, created/ready/unreferenced/last_access/deleting/deleted_at
MediaBlob     : blob_id, object_id, owner_id, owner_scope, isolation_domain,
                digest_kind/digest_version/content_digest, size, mime,
                storage_backend, storage_key, envelope_mode/version, dedup_eligible,
                status(STAGED|VERIFIED|ACTIVE|RETIRING|DELETED), pinned_until, created/verified/retiring/deleted_at
MediaVariant  : variant_id, media_id, kind, blob_id, status(pending|processing|ready|failed|skipped),
                mime, codec, width/height/duration_ms/bitrate_bps/size,
                generation, derived_from, is_primary, failure_reason, created/ready_at
MediaReference: reference_id, media_id, owner_id, variant_kind, business_type, business_id,
                room_ref, permission_scope, ref_kind(observed|declared), state(active|released),
                created_at, released_at, release_reason
MediaAccessGrant: grant_id, media_id, variant_scope, subject_type/subject_id, permission,
                derived_from, grant_version, expires_at, single_use, uses, max_uses,
                issued_by, created_at, revoked_at/reason
MediaUploadSession: upload_id, owner_id, origin_domain, kind, declared_size/mime,
                digest_claim(+kind), envelope_mode/version, part_size, chunks, uploaded_bytes,
                status, media_id, idempotency_key, created/updated/expires_at
MediaGcRun    : run_id, mode, scope, scanned/candidates/collected,
                skipped_{pinned,referenced,grace,quarantined}, bytes_reclaimed,
                decisions, started/finished_at, error_code
```

**变体枚举**：图片 `original / thumbnail / preview / compressed`；
视频 `original / poster / preview_video / 360p / 720p / 1080p`；
音频 `original / compressed`；文件 `original`。每种媒体类型有允许集合与回退顺序（`VARIANT_FALLBACK_ORDER`）。

**归属规则（冻结）**：`ref_count` 是缓存，真相源是 `media_references`；
`media_id`/`blob_id` 为不透明 UUID，永不由摘要派生（测试断言键/令牌中不含摘要）。

---

## 5. Gateway 设计

```python
class MediaGateway(Protocol):
    def can_resolve(self, reference: str) -> bool
    def resolve(self, reference: str, *, subject_id: str) -> MediaResolution
    def authorize(self, *, media, subject_id, permission, variant_kind, visibility) -> AccessDecision
    def resolve_variant(self, media_id, *, media_kind, prefer, network, allowed_kinds) -> VariantCandidate | None
```

| 适配器 | 归它管的引用 | 行为 |
| --- | --- | --- |
| `BusinessMediaGateway` | 平台 `media_id`、`media://…`、`/api/v1/moments/media/content/…` | 平台对象：返回变体清单 + `delivery=platform`；遗留引用：返回 `delivery=legacy_capability` 且 `read_old_only=true`（**Read Old**，不复制字节） |
| `MatrixMediaGateway` | `mxc://…` | 解析出 locator、返回 `delivery=matrix_token` + `requires_matrix_token=true`；`authorize` 返回 `DELEGATED`（授权归 Matrix），平台**不**为 E2EE 字节建身份 |

**为什么 Matrix 适配器不建平台对象（实现期间的关键决定）**：
服务器无法为 E2EE 附件计算权威摘要（它看不到明文，而客户端声明的摘要按 ADR-002 不可信），
若为它编造一个身份（例如用 locator 字符串做摘要）就会破坏摘要模型。因此 Phase 4 选择
"解析 + 委派授权 + 不建对象"，这同时满足"旧媒体可读""不迁移字节""不破坏 E2EE"三条要求；
把 Matrix 媒体纳入平台对象（locator 型对象）需要新的身份语义，列为后续阶段的开放项。

**Variant Resolver**：`prefer(auto|data_saver|quality)` × `network(unknown|slow|wifi|ethernet)` × 媒体类型
→ 有序候选；**只返回 `ready`**；授权范围（`variant_scope`）在排序之后过滤，因此调用方无法通过"要更好的档位"提权。
测试覆盖：未就绪的 `thumbnail` 被忽略、范围只收窄不放宽。

**Upload Engine（ADR-005）**：独立子系统。`POST /media/platform/uploads` 建会话（幂等）、
`GET` 断点续传状态、`DELETE` abort 均可用；`PUT .../parts/{n}` 与 `POST .../complete` 返回
`501 MEDIA_UPLOAD_NOT_IMPLEMENTED`，响应体显式声明 `chunk_upload_supported=false` /
`commit_supported=false` / `resume_supported=true`，客户端可特性探测而不是猜。

---

## 6. Reference 设计

```
message ─┐                                  ┌─ MediaObject(media_id)
moment  ─┼─▶ MediaReference(business_type/business_id) ─┤
profile ─┘                                  └─ （权限/生命周期都挂在对象上）
```

| 规则 | 实现 |
| --- | --- |
| 幂等 | `(media_id, business_type, business_id)` 在 `active` 时唯一；重复 attach 返回同一条 |
| 引用计数可重算 | `_recount_in_session` 每次 attach/release 后从引用表重算 `ref_count` |
| 释放 ≠ 删除 | `release` 只置 `released` + `released_at` + `release_reason`，字节保留 |
| observed / declared | `ref_kind` 区分服务端可观测与客户端声明；E2EE 域只接 observed（不回填消息引用） |
| 隔离 | 明文域：仅对象 owner 可 attach/release；E2EE 域：每个上传者持有自己的引用行 |
| 按业务释放 | `release_for_business` 只释放 `actor_id` 自己的引用，绝不代释放他人 |

---

## 7. Authorization 设计

**判定顺序（fail-closed）**：owner → 显式 `user` grant（且档位在 `variant_scope` 内）→ 拒绝。
audience 读取**不在这里**判定：audience 通过 Signed URL 交付，并在每次交付时复核 grant 状态与版本，
因为平台不拥有"谁是群成员/谁可见动态"的事实，靠猜会变成弱点。

**Signed URL**：`HMAC-SHA256(base64url(claims))`，claims = `{v, kv, m, k, s, a, p, t, e, j, g, gv, su}`。
- `e`（过期）由**服务端**写入；API 上不存在 `expires_in` 参数（客户端传入会被严格模型 422 拒绝）。
- `private`：要求调用方身份 == `s`，否则 404；因此转发私有 URL 无效（测试覆盖）。
- `audience`：`s` 为受众引用（如 `room:!r`），任何持有者可用（冻结取舍），但**撤销即时生效**：
  交付时读取 grant，`revoked_at` 或 `grant_version` 不符即 404（测试覆盖）。
- 篡改签名 / 未知版本 / 过期一律折叠为**同一个 404**，不泄露对象是否存在。
- 令牌不含摘要、路径、文件名；测试断言 claims 键集合与内容。

**Grant**：`grant_version` 在撤销时递增；`single_use`/`max_uses` 通过 `consume()` 原子计数
（`with_for_update`），单次授权端到端只成功一次（测试覆盖）。

---

## 8. Lifecycle 设计

```
Remove Reference → Check References → Mark ORPHAN → (grace) → DELETING → DELETED
                                   └─ 仍有 active 引用 → 不动
```

| 保护 | 依据 |
| --- | --- |
| 有 `active` 引用 | 重算引用数后再判定，绝不信任缓存列 |
| `pinned_until > now` | pin 是正交属性（`pin_object`/`unpin_object`） |
| 未过宽限期 | `orphan_grace_seconds`（明文） |
| E2EE 保留下限 | `max(grace, e2ee_retention_floor_seconds)`，因为 E2EE 引用不可数 |
| `quarantined_at` | 保留摘要墓碑，防止"换用户重传被封禁内容" |
| 在途上传会话 | `media_upload_sessions` 非终态时跳过 |

**GC 报告与审计**：每次运行写 `media_gc_runs`（mode/scope/scanned/candidates/collected/各类 skipped/bytes/decisions）。
`decisions` 只含 `media_id`(不透明) + action + reason，测试断言不含路径/摘要/`@`/`Bearer`。
**恢复**：`DELETING` 状态的对象在下一次运行被识别为 `recover_deleting` 并完成删除；
删除顺序是"先标记 RETIRING → unlink → 标记 DELETED"，崩溃不会留下无声的数据丢失。

**状态机非法流转**（如 `ACTIVE → DELETED`）由 `assert_status_transition` 拒绝（409）。

---

## 9. Migration 策略

| 任务书要求 | 实现 |
| --- | --- |
| Migration Adapter | `BusinessMediaGateway.resolve` 的 **Read Old** 分支（`media://` + 能力 URL）+ `MomentsMediaBridge`（**Write New**）；`MatrixMediaGateway` 提供 Matrix 侧只读兼容 |
| Read Old | 旧能力 URL 无需迁移即可解析与读取；测试断言此过程**不创建**任何平台对象 |
| Write New | 新上传经 `POST /media/platform/objects` 或 `/media/platform/moments/attachments` 进入平台 |
| 逐渐减少旧路径 | 旧路径保持可用；新客户端切到平台后，旧路径调用自然下降；**不做**强制迁移、不做历史扫描 |

**数据库迁移**：`0069_media_platform` 仅 `create_table` + `create_index`（含部分唯一索引），
无 `alter`/`drop`；`downgrade` 仅删本次新增的索引与表。`alembic upgrade head --sql` 已验证可渲染。

**OpenAPI**：新增 14 条路由已重新导出（`packages/api-contracts/openapi/liuhetong-v1.yaml`，
+2028 行），`export_openapi.py --check` 由 drift 转为 **PASS**。

---

## 10. Matrix 兼容

| 要求 | 实现 |
| --- | --- |
| 不迁移 Matrix 字节 | 无任何字节搬移/重加密/事件重写；测试断言 legacy 解析后平台表为 0 行 |
| MatrixMediaGateway Adapter | 已实现（`resolve` + `authorize` 委派） |
| 双读 | `MediaGatewayRegistry.resolve` 先按 scheme 匹配遗留引用（`mxc://` / `media://` / 能力 URL），再落到平台对象 |
| 惰性索引 | 平台对 Matrix 媒体**不建对象**（理由见 §5）；`read_old_only=true` 明确表达"只读旧路径" |
| 不双写旧数据 | Chat 上传路径**零改动**，仍走 SDK → `/_matrix/media/v3/upload` |

**E2EE 边界**：平台从不接收明文摘要、从不持有附件密钥、从不解密或转码；
`DigestKind.CIPHERTEXT` 是密文域唯一身份来源，且只有确定性信封 + 门槛以上才允许复用。

---

## 11. Moments 接入

### 11.1 零侵入的桥接方式

```
Client ──POST /api/v1/media/platform/moments/attachments（+ Idempotency-Key）──▶ MomentsMediaBridge
   │  ① 复用既有校验（mime 白名单 / 20MiB / GIF 容器）
   │  ② 平台 ingest：MediaObject + MediaBlob + MediaVariant（明文域、audience 可见性）
   │  ③ 既有 moment_media_uploads 增加一行：object_key = 平台 blob 的 storage_key，status=COMPLETED
   │  ④ 平台引用 MOMENT_UPLOAD；返回既有形态的 capability URL
   ▼
既有 POST /api/v1/moments（**未修改**）→ media://<key> → 既有 GET /api/v1/moments/media/content/{token}（**未修改**）
```

**为兼容既有读者做的一处键布局调整**：平台 blob 键加一个**遗留命名空间前缀**
（`moments/media/user/<scope-hash>/<blob-id>.jpg`）。原因：既有 Moments 读者只识别
`media://moments/...` 前缀。隔离地址（`media/user/<scope-hash>`）仍在路径中并仍被
`key_belongs_to_domain` 校验，命名空间是代码内白名单字面量（不接受用户输入）。
测试断言：键以 `moments/` 开头、包含 `/media/user/`、**不含**原始 `user-a`。

### 11.2 生命周期衔接

- 附件建立 ⇒ 平台引用 1 条（`MOMENT_UPLOAD`）；`ref_count` 可被 GC 计数。
- 删除动态/放弃附件 ⇒ `POST /api/v1/media/platform/releases`（只释放调用者自己的引用）。
- 释放后对象进入 `ORPHAN`，超过宽限期由 GC 回收（测试端到端覆盖）。

### 11.3 既有 Moments 回归

`tests/business_api/moments` + `tests/business_api/media` **106 条全部通过**，未修改其中任何文件。

---

## 12. 测试结果

| 范围 | 命令 | 结果 |
| --- | --- | --- |
| 新增测试（5 个文件） | `py -3.12 -m pytest tests/business_api/media_platform -q` | **71 passed** |
| 既有 Moments / 媒体回归 | `py -3.12 -m pytest tests/business_api/moments tests/business_api/media -q` | **106 passed** |
| 合计（本次回归命令） | 上述两目录一起 | **177 passed** |
| 合同漂移 | `py -3.12 scripts/export_openapi.py --check` | **PASS**（重新导出后） |
| Flutter 静态分析 | `flutter analyze` | 见 §12.1 |
| Flutter 全量测试 | `flutter test --timeout 120s` | 见 §12.1 |
| Flutter 边界（仓库门禁） | `py -3.12 -m pytest tests/mobile -q` | 见 §12.1 |
| HTML demo | `npm test`（`frontend/`） | 见 §12.1 |
| 仓库整体门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | 见 §12.1 |

### 12.1 门禁结果

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| Flutter 静态分析 | `flutter analyze` | **No issues found!**（21.3s） |
| Flutter 全量测试 | `flutter test --timeout 120s` | **3120 通过 / 0 失败**（退出码 0） |
| 本次新增测试 | `py -3.12 -m pytest tests/business_api/media_platform -q` | **71 通过 / 0 失败** |
| 既有 Moments + 媒体回归 | `py -3.12 -m pytest tests/business_api/moments tests/business_api/media -q` | **106 通过 / 0 失败**（未修改其中任何文件） |
| Flutter 边界（仓库门禁子集） | `py -3.12 -m pytest tests/mobile -q` | **70 通过 / 0 失败**（333.27s） |
| HTML demo | `npm test`（`frontend/`） | **209 通过 / 0 失败** |
| OpenAPI 合同 | `py -3.12 scripts/export_openapi.py --check` | 先 **drift**（新增 14 条路由）→ 重新导出后 **PASS** |
| 仓库整体门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | **`Verification: PASS`（退出码 0）** |

`scripts/verify.ps1` 内的关键子步骤（本次实际输出）：`Alembic migrations: PASS`（链路含
`0068_red_packet_fee -> 0069_media_platform`）、`OpenAPI contract: PASS`、`Docker Compose render` 通过。

### 12.1.1 门禁发现并修复的两个真实问题（记录在案）

| # | 现象 | 根因 | 处置 |
| --- | --- | --- | --- |
| G1 | `tests/business_api/test_migrations.py::test_wallet_and_moments_merge_is_the_only_head` 与 `test_wallet_release_baseline.py::test_wallet_and_moments_production_branches_have_one_shared_head` 失败（`['0069_media_platform'] != ['0068_red_packet_fee']`） | 两条基线用例**把集成迁移 head 钉死在 `0068_red_packet_fee`**；新增 expand-only 迁移必然改变 head | 按 expand-migrate 流程更新基线到 `0069_media_platform`（并追加 `0068 -> 0069` 历史断言）；`test_migrations.py` + `test_wallet_release_baseline.py` + `test_openapi_contract.py` **17 通过** |
| G2 | `export_openapi.py --check` 报 drift | 新增 14 条 `/media/platform/**` 路由未进入合同 | 运行 `scripts/export_openapi.py` 重新导出（+2028 行），复查 **PASS**；合同与实现同步由门禁持续保证 |

`scripts/verify.ps1` 首次运行（G1 未修复时）结果为 `business_api + business_worker` 用例
`2002 passed / 2 failed / 58 skipped`，失败即上述两条 head 断言；修复后相关用例重跑通过，
整体门禁以 **`Verification: PASS`（退出码 0）** 收尾。

### 12.2 任务书 8 条必测用例对照

| 用例 | 位置 | 断言要点 |
| --- | --- | --- |
| **Test 1 MediaObject** | `test_media_domain_core.py` | ingest 产出恰好 1 object + 1 blob + 1 ready 主变体；关系与字段正确；未引用对象由宽限期保护 |
| **Test 2 Reference** | `test_media_references_lifecycle.py` | chat + moment 两条引用；释放其一后对象仍存在、另一条引用仍在、字节仍可读 |
| **Test 3 Authorization** | `test_media_authorization.py` | private：A 读成功；B 直接读 403；B 用 A 的 URL 404；匿名 404 |
| **Test 4 Audience** | `test_media_authorization.py` | audience 令牌另一用户可读（冻结取舍）；撤销 grant 后同一 URL 立即 404 |
| **Test 5 Matrix Adapter** | `test_media_gateway.py` | `mxc://` 可解析、`delivery=matrix_token`、`delegated_to=matrix`、`requires_matrix_token=true` |
| **Test 6 Migration** | `test_media_gateway.py` + `test_media_moments_integration.py` | 遗留能力 URL 与"旧式上传"均可读，且过程中**平台零对象**（无需迁移） |
| **Test 7 GC** | `test_media_references_lifecycle.py` | 无引用 → dry-run 报告 `would_collect`、enforce 后 `DELETED` 且文件消失；有引用 → `has_references` 跳过 |
| **Test 8 Variant** | `test_media_gateway.py` | 只返回 ready 变体；图片/视频在多组 `prefer`×`network` 下选档正确；授权范围只收窄 |

### 12.3 安全测试（任务书 §13）

| 要求 | 用例 |
| --- | --- |
| 用户 A 不能访问用户 B 的 private media | `test_other_user_cannot_read_private_object`（403 且不泄露存在性）、`test_private_token_works_for_owner_and_not_for_a_forwarder` |
| private URL 转发失败 | 同上（404 统一错误体） |
| audience 允许但有 TTL | `test_audience_token_is_shareable_inside_the_audience` + `test_client_cannot_extend_the_ttl`（`expires_in` 被拒） |
| 删除引用不误删其他引用 | `test_releasing_one_reference_never_removes_another_references_media`、`test_release_for_business_never_touches_another_users_reference`、`test_releasing_a_moment_reference_leaves_other_media_alone` |
| 额外：跨类摘要不可比较 | `test_digest_kinds_never_compare`、`test_transport_digest_cannot_become_an_object_identity` |
| 额外：本地攻击者无法开启全局明文去重 | `test_dedup_policy_refuses_cross_user_plaintext_even_if_configured` |
| 额外：路径穿越 | `test_blob_backend_rejects_path_traversal` |
| 额外：令牌/审计无 PII | `test_token_payload_carries_no_sensitive_fields`、`test_gc_audit_row_has_no_sensitive_fields`、`test_metrics_cover_required_observations_and_carry_no_pii` |

---

## 13. 性能指标

实现的可观测项（任务书 §12 要求）：

| 指标 | 采集点 | 隐私 |
| --- | --- | --- |
| `media_resolve_ms` | `BusinessMediaGateway.resolve` / `MatrixMediaGateway.resolve` | 只有耗时 |
| `variant_resolve_ms` | `VariantResolver.candidates` | 只有耗时 |
| `authorization_ms` | `OwnerOnlyAuthorizer` / `GrantAuthorizer.authorize` | 只有耗时 |
| `storage_read_ms` | `MediaRepository.read_bytes` | 只有耗时 |
| `cache_hit` / `cache_miss` | 授权快路径命中/未命中（每次读取至少计一次） | 只有计数 |
| 其它计数 | `object_created/reused`、`blob_written/read`、`reference_attached/released`、`grant_issued/revoked`、`signed_url_issued/rejected`、`authorization_denied`、`gc_run/collected/bytes_reclaimed`、`legacy_read_delegated`、`moments_bridge_attached`、`upload_session_*` | 只有计数 |

- **禁止内容**：无用户 ID、room/event ID、token、key、摘要、路径、消息内容（`MediaPlatformMetrics.debug_line()` 只输出数字 JSON）。
- **采集开关**：计数**无条件累加**（保证"是否命中"在非性能构建下也可判定）；耗时采样受
  `CHATFLOW_MEDIA_METRICS=1/true/yes` 控制，样本上限 512，避免运行时开销。
- **读取方式**：`GET /api/v1/media/platform/metrics`（维护令牌门控；生产未配置令牌时 503，fail-closed）。

**设计约束的落地**：元数据路径不引入逐请求写放大（`touch` 只在读取成功时更新一次 `last_access_at`）；
GC 限 `limit`（默认 200，最大 1000）、可 dry-run、可中断；无新缓存层（"不创建第二套缓存"）。

---

## 14. 安全测试

见 §12.3 对照表。补充说明：

| 面 | 状态 |
| --- | --- |
| hash 泄露 / 存在性探测 | 不提供任何"按摘要查询"的接口；摘要不入令牌/审计/指标；`ETag` 未引入摘要；`media_id` 不透明 |
| URL 泄露 | 服务端 TTL；private 绑定 subject；audience 可转发但可撤销；篡改/过期统一 404 |
| 越权访问 | fail-closed；变体级授权；非 owner 不能 attach/release/发 grant/pin；跨用户读私有对象 403；`media_id` 不可枚举（UUID） |
| replay | 引用与上传会话幂等；上传 create 强制 `Idempotency-Key`（同键异参 409）；`single_use`/`max_uses` 原子消费 |
| token 盗用 | 短 TTL（private 60s 级、audience 600s 级、public 86400s 级，均可配置）；撤销即时生效；令牌不写日志 |
| reference 污染 | 引用写入校验 owner + 对象状态；明文域只有 owner 可引用；业务释放只作用于调用者自己的引用 |
| CDN 滥用 | 本阶段不启用 CDN；令牌设计已按 ADR-003 分级（audience 可共享、private 不可），供 CDN 阶段直接使用 |

**残余风险（诚实记录）**：确定性加密下的可链接性（ADR-0060 已接受）；
audience 令牌在有效期内可被受众成员外传；数据库泄露场景下摘要表本身可被离线比对（DEFERRED-10 的 HMAC 索引未实施）；
E2EE 内容不可扫描（服务端无明文）。

---

## 15. Remaining Risks

| # | 风险 | 影响 | 缓解 / 下一步 |
| --- | --- | --- | --- |
| R1 | Matrix 媒体未纳入平台对象（无 locator 型身份） | 平台无法对 E2EE 附件做引用计数/配额口径统计 | 明确的设计选择（§5）；后续阶段可引入 locator 型对象（ADR-002 扩展），需新 ADR |
| R2 | 上传引擎只实现接口，1GB+ 仍不可用 | 大视频能力未交付 | 任务书 §10 明确本阶段只做接口；下一步实现分片/续传（含 E2EE 先加密再分片与 CTR 计数器连续性） |
| R3 | 引用释放依赖调用方（新客户端）触发 | 若客户端不调用 `releases`，对象只能等宽限期后被 GC | 宽限期 + GC 兜底；客户端接入列入下一阶段 |
| R4 | 无 CDN、无对象存储 | 万人并发与跨区分发仍受单机限制 | DEFERRED-12；本阶段已把 Signed URL/缓存分级设计落到代码，便于后续直接接 CDN |
| R5 | 明文域服务端转码未实现 | 视频多档位/渐进播放对 Moments 视频不可用 | DEFERRED-6；E2EE 域本就只能端侧生成 |
| R6 | 无配额计量落地（仅口径） | 无法按用户限流/计费 | 指标已就绪，配额值为 DEFERRED-14 |
| R7 | 未做真机/负载验证 | 性能目标未验证 | 需沿用 `scripts/loadtest` 场景分档验收（200/500/1000 VU） |
| R8 | `media_gc_runs.decisions` 随批次增长 | 表体积 | 已有 `limit` 上限；后续可加保留期清理 |
| R9 | 签名密钥回退到头像密钥 | 轮换影响面耦合 | 生产建议配置独立 `BUSINESS_MEDIA_URL_SIGNING_SECRET`（已支持；未配置时回退并在文档说明） |
| R10 | 新增路由未接入客户端 | 能力已就绪但用户不可见 | 客户端接入为下一阶段工作（含 `prefer`/`network` 选档与 501 特性探测） |

---

## 门禁执行记录

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 1 | `flutter analyze`（`apps/mobile_flutter`） | No issues found!（21.3s） |
| 2 | `flutter test --timeout 120s` | 3120 通过 / 0 失败（退出码 0） |
| 3 | `py -3.12 -m pytest tests/business_api/media_platform -q` | 71 通过 |
| 4 | `py -3.12 -m pytest tests/business_api/moments tests/business_api/media -q` | 106 通过 |
| 5 | `py -3.12 -m pytest tests/mobile -q` | 70 通过（333.27s） |
| 6 | `npm test`（`frontend/`） | 209 通过 / 0 失败 |
| 7 | `py -3.12 scripts/export_openapi.py --check` | drift → 重新导出 → PASS |
| 8 | `pwsh -NoProfile -File scripts/verify.ps1` | **Verification: PASS（退出码 0）** |

未执行项：真机测试、APK/IPA 构建、部署、负载压测（200/500/1000 VU）——均不在本阶段范围，
且任务书未授权；性能目标因此在报告中标注为"未验证目标"（§13 与 R7）。

## 附：实现期的三次自我纠正（供评审参考）

| # | 问题 | 影响面 | 处置 |
| --- | --- | --- | --- |
| F1 | `dedup_eligible` 一度被当成"策略允许复用"的返回值使用 | 明文对象会占用**跨用户**摘要槽，`uq_media_objects_digest_slot` 冲突（同一用户第二次上传同字节直接报错） | 拆成两个概念：`cross_user_eligible`（ADR-002 谓词，决定是否占用摘要槽）与 `reuse_attempt`（策略决定是否查找可复用行）；明文复用只在 owner scope 内查找 |
| F2 | 单次使用授权的测试是"手工 consume"而非端到端 | 覆盖不到真实交付路径 | 改为端到端：给 user-b 发 `single_use` 授权 → 首次读取 200 → 再次读取 403 `MEDIA_GRANT_EXHAUSTED` |
| F3 | 平台 blob 键前缀与既有 Moments 读者约定不符 | 桥接后动态读图 404（附件校验只认 `media://moments/...`） | 引入白名单式命名空间前缀（`moments/`），隔离地址（`media/user/<scope-hash>`）仍保留在路径中并被 `key_belongs_to_domain` 校验 |
