# ChatFlow Media Engine Phase 3 — Server Architecture

> ## 本阶段：**Architecture Design Only**
>
> **只设计，不编码。** 本文档**没有**实现任何功能：没有修改 Matrix Server、Matrix 协议、E2EE、
> 媒体上传接口、朋友圈 API、数据库 schema 或客户端缓存代码；没有新增数据表、没有新增端点、
> 没有部署。文中的 schema、接口、状态机、阈值与容量数字**全部是提案**（proposal），
> 不是现状描述。任何"现状"陈述都标注证据 `path:line`；任何"提案"都标注
> **【提案】**。
>
> 本阶段也**不实现**用户明确排除的内容：全球媒体去重、CDN 改造、服务端对象迁移
> （这三项属于 Phase 3 后半阶段，见 §14 与 §17）。
> Phase 4 的能力（AI 媒体分析、智能压缩、自动标签、图片搜索、视频理解）**只列路线图**，见 §17。

- **日期**：2026-09-17（Asia/Hong_Kong）
- **仓库**：`SuperJJ2333/StarChat`（分支 `main`，基线 `81d9e612`）
- **前置**：[现状审计](media-engine-phase3-server-audit.md)（本次服务端审计，含全部证据）、
  Phase 0 [`media-engine-v1.md`](media-engine-v1.md)、Phase 1 [`2026-09-17-media-engine-v1-phase1.md`](../verification/2026-09-17-media-engine-v1-phase1.md)、
  Phase 2 [`media-engine-phase2-local-index.md`](media-engine-phase2-local-index.md)、
  客户端审计 [`2026-09-17-media-architecture-audit.md`](../verification/2026-09-17-media-architecture-audit.md)
- **约束**：保持 E2EE 安全、Matrix 兼容、渐进迁移、不破坏已有用户数据。

---

## 目录

1. [Current Architecture](#1-current-architecture)
2. [Problems](#2-problems)
3. [Goals](#3-goals)
4. [MediaObject Design](#4-mediaobject-design)
5. [MediaVariant Design](#5-mediavariant-design)
6. [MediaReference Design](#6-mediareference-design)
7. [Encryption Dedup Analysis](#7-encryption-dedup-analysis)
8. [Permission Model](#8-permission-model)
9. [Lifecycle](#9-lifecycle)
10. [Upload Protocol](#10-upload-protocol)
11. [Download Protocol](#11-download-protocol)
12. [CDN Design](#12-cdn-design)
13. [Database Schema](#13-database-schema)
14. [Migration Strategy](#14-migration-strategy)
15. [Security Analysis](#15-security-analysis)
16. [Performance Analysis](#16-performance-analysis)
17. [Phase 4 Roadmap](#17-phase-4-roadmap)

附录：[A 目标架构总览](#附录-a-目标架构总览) ·
[B 术语表](#附录-b-术语表) ·
[C 开放问题（需产品/隐私/运维决策）](#附录-c-开放问题需产品隐私运维决策)

---

## 0. 目标架构一页图

用户要求的最终形态——**一个媒体平台，四类消费者，共享对象/变体/引用/权限/生命周期/存储/CDN**：

```
                          ┌───────────────────────────────────────────┐
                          │        Media Platform（Phase 3 设计）      │
                          │  Media Gateway（唯一入口）                 │
                          │   · Object / Variant / Reference / Grant   │
                          │   · Upload Session / Lifecycle / GC        │
                          │   · Policy（授权、配额、可见性）            │
                          └───────────────┬───────────────────────────┘
                                          │
        ┌──────────────┬──────────────────┼──────────────────┬────────────────┐
        │              │                  │                  │                │
      Chat           Moments            Avatar             File/Group      (Phase 4)
   E2EE 附件      业务明文图片       公开/半公开图片       通用附件附件      AI 分析/搜索
        │              │                  │                  │
        └──────────────┴────────┬─────────┴──────────────────┘
                                │
                    ┌───────────┴────────────┐
                    │  Blob Store（字节层）   │   ← 现在：Matrix media_store
                    │  内容寻址 + 加密信封    │      与 business-media 两个目录
                    └───────────┬────────────┘
                                │
                    ┌───────────┴────────────┐
                    │  Metadata DB（元数据）  │   ← 现在：Matrix PG + business PG
                    └───────────┬────────────┘
                                │
                    ┌───────────┴────────────┐
                    │  Edge / CDN（可选层）   │   ← 现在：不存在
                    └───────────┬────────────┘
                                │
                            Client Cache（Phase 2 已交付的本地索引）
```

**与现状的对应关系**（详见 [审计](media-engine-phase3-server-audit.md)）：

| 目标概念 | 现状载体 | 差距性质 |
| --- | --- | --- |
| Blob（字节层） | Matrix `media_store` 文件 + 业务 `data/business-media` 文件 | 两套、无共同抽象、无内容寻址（业务侧） |
| 去重索引 | `chatflow_media_blobs(digest → media_id)`（**仅 Matrix 密文**） | 只覆盖一个域 |
| Reference | `chatflow_media_references(media_id, user_id)` | 语义是"上传者"，不是"业务引用" |
| Variant | 无 | **完全缺失** |
| Grant | 无（Matrix 靠房间成员资格；业务靠能力 URL） | 无统一模型 |
| Collection/GC | 补丁的 `unreferenced_ts + grace + retiring` + 管理员 purge（未调度） | 未自动化、无业务侧对应物 |

---

## 1. Current Architecture

> 本章是**现状**（有证据）。完整证据链见 [服务端审计](media-engine-phase3-server-audit.md)，此处只保留设计所需的最小事实集。

### 1.1 三条上传链路（真实存在的三条）

```
① Chat / File / Group（E2EE）
   Client ──压缩/缩图/抽帧──▶ 确定性信封(HKDF(sha256(明文))→key/IV, AES-256-CTR)
          ──Megolm 加密事件(Megolm 内携带 chatflow_media.content_sha256)──▶
   POST /_matrix/media/v3/upload（body = 密文）
          ──▶ Synapse + ChatFlow 补丁：流式密文摘要 → 查重 → 复用 media_id
              → chatflow_media_blobs / chatflow_media_references
          ──▶ 事件 content['file'] = {url: mxc://…, key, iv, hashes.sha256=密文摘要}

② Moments（业务明文）
   Client ──压缩≤1080px/≤500KB──▶ POST /api/v1/moments/media/uploads {mime,size}+Idempotency-Key
          ──▶ PUT …/{id}/content（明文字节）
          ──▶ LocalPrivateObjectStorage.put("moments/{actor}/{uuid4}{ext}")
          ──▶ POST …/{id}/complete → 动态记录写 media://{key}
   GET /api/v1/moments/media/content/{token}（无鉴权）→ 可见性复核 → 明文图片

③ Avatar（业务明文）
   Client ──▶ POST /api/v1/profile/avatar/uploads {mime,size} → PUT content → POST complete
          ──▶ avatars/{user_id}/{uuid4}{ext} + users.avatar_object_key
          ──▶（异步）worker 把同一份字节**再上传一份到 Matrix** → users.matrix_avatar_mxc_uri
```

### 1.2 现状要点（对设计有约束力的事实）

| 事实 | 证据 |
| --- | --- |
| 明文摘要**从不**离开客户端进入 E2EE 上传链路；服务器只看到密文与密文摘要 | `docs/adr/0060-content-addressed-media-dedup.md:17` |
| 确定性加密 ⇒ 相同明文 = 相同密文 ⇒ **密文摘要去重 ≡ 内容去重**（跨用户） | `docs/adr/0060-content-addressed-media-dedup.md:11`；`third_party/synapse/chatflow_media_dedup.py:191-240` |
| 引用是 `(media_id, user_id)`（上传者维度），**不是**消息/业务维度 | `third_party/synapse/README.md:37-38` |
| 宽限期 ≠ 自动回收；物理回收靠管理员/retention purge（当前未调度） | `third_party/synapse/README.md:47-49` |
| 业务侧 key 全是随机 UUID，**无内容寻址**；朋友圈删除不解引用、封面替换不删旧对象；**无任何 GC/配额/计量** | 审计 §2.3、§2.2 |
| 业务读取端点**无鉴权**（Bearer capability），头像/渲染 TTL 由客户端 `expires_in` 决定（可到 7 天） | 审计 §2.3、风险 A13/A14 |
| 上传上限实际是 Synapse `max_upload_size: 50M`；无分片、无续传 | `data/synapse/homeserver.yaml:77` |
| 无 CDN、无代理缓存、全 `no-store`；业务媒体一律回源 | 审计 §4.3、§4.5 |
| 媒体字节与数据库**同机同盘**，无副本；仓库内无备份脚本 | 审计 §4.1、§4.7 |
| 媒体写路径有**全局数据库锁**，文档要求"分片前先测量" | `third_party/synapse/README.md:33-36` |
| 实测容量：200 VU 六轮 PASS；500 VU 首次升档 2 轮 FAIL、预热后 PASS；**千人未验收** | `docs/verification/2026-09-10-media-capacity-runtime.md` |

### 1.3 现状的"隐藏资产"

Phase 3 不需要从零造：Matrix 侧已有一个**可用的服务端对象骨架**（内容寻址 + 引用 + 宽限期 + 隔离墓碑 + 崩溃恢复协议）。
Phase 3 的设计任务是：**把它抽象成"域的无关"的对象平台，并让业务域接入**，而不是替换它。

---

## 2. Problems

按"设计必须回答"的方式列出，每条都指向 §3 的目标与后续章节的方案。

| # | 问题 | 现状证据 | 设计上必须回答 |
| --- | --- | --- | --- |
| P1 | **同一份字节在四个地方各存一份**：聊天（密文）、朋友圈（明文）、头像（业务明文 + Matrix 密文复制品） | 审计 §2.3、客户端审计 `:32` | 跨域如何共用一份 blob，且**不破坏 E2EE**？→ §4/§7 |
| P2 | **业务侧没有内容寻址**：随机 UUID key，重复上传产生多个对象 | `modules/moments/media.py:128-131`；`api/media.py:66-71` | 业务域（服务器本来就有明文）如何做零成本内容寻址？→ §4/§7 |
| P3 | **没有变体体系**：只有"原图/缩略图"与"转码/封面"，无法按网络/屏幕选档，无法渐进播放 | 客户端审计 §1.4 | Variant 模型与转码流水线 → §5/§16 |
| P4 | **引用语义错位**：服务器只有"上传者引用"，没有"业务引用"；无法回答"这张图还有谁在用" | `third_party/synapse/README.md:37-38` | 业务引用 + 计数 + 与 E2EE 不可见性的调和 → §6/§9 |
| P5 | **没有回收**：业务孤儿对象永久驻留（朋友圈删除、封面替换、渲染产物、`SCANNING` 滞留）；Matrix 侧回收未调度 | 审计 §2.2 | 自动化 GC 与"不可回收时必须诚实"的边界 → §9/§13 |
| P6 | **没有配额/计量/审计/指标**：无法治理滥用，无法容量规划 | 审计 §4（A4/A17） | 配额与可观测性模型 → §13/§15/§16 |
| P7 | **权限模型三种互不兼容**：Matrix 房间成员资格、Moments 能力 URL + 可见性复核、Avatar 无 viewer 的能力 URL；三个读取端点无鉴权 | 审计 §2.3（A13/A14） | 统一 Grant 模型 + 令牌绑定 viewer/用途/次数 → §8/§11 |
| P8 | **大文件不可用**：50 MiB 上限、无分片、无续传、无后台重试 | `homeserver.yaml:77` | 分片/续传/校验协议 + 与去重、E2EE 的相互作用 → §10 |
| P9 | **无边缘分发**：全 `no-store`，万人并发直接压单机磁盘 | 审计 §4.3/§4.5 | CDN 与"鉴权 vs 可缓存"矛盾的解法 → §12 |
| P10 | **单点风险**：字节与 DB 同机同盘、无副本、无仓库内备份脚本 | 审计 §4.1/§4.7 | 存储抽象与恢复点定义 → §13/§14 |
| P11 | **写路径全局串行**：媒体写在同一把 DB 锁上 | `chatflow_media_dedup.py:32` | 分片策略与"先测量"门禁 → §16 |
| P12 | **能力 URL 可被放大/洗白**：TTL 客户端可控；过期 URL 可被写成永久引用 | 审计 §3（A13/A15） | 令牌设计（TTL 服务端强制、单次、绑定 viewer）→ §8/§15 |

---

## 3. Goals

### 3.1 目标（本阶段设计要达到的形态）

| 目标 | 可验收的描述 |
| --- | --- |
| G1 统一媒体对象体系 | 任何域（Chat/Moments/Avatar/File）产生的一份媒体，都能用同一个 `media_id` 指代，并挂多个业务引用 |
| G2 多版本媒体体系 | 一份媒体可有多个 variant（图片多分辨率；视频 360/720/1080 + poster + preview），消费者按条件选档 |
| G3 权限体系 | 统一 Grant：subject + permission + expires_at；读取可撤销、可绑定 viewer、可单次 |
| G4 生命周期体系 | Upload→Read→Delete 三段的显式状态机 + 自动 GC + 配额 + 计量 + 审计 |
| G5 跨域去重（保守版） | 至少做到**域内**内容寻址（业务域零成本获得；E2EE 域已有）；域间去重只做"同演绎版参数"时命中，不做参数归一化（那会改变发送字节） |
| G6 大文件能力 | 分片 + 续传 + 校验 + 幂等完成；支持 1GB+ 视频（同时解掉当前 50 MiB 天花板） |
| G7 渐进视频 | `poster → preview_video → 目标档位 → 原片` 的分层获取，首帧可播时间不随文件大小线性增长 |
| G8 边缘分发 | CDN 分级：可缓存的内容用可缓存 URL；不可缓存的内容明确"只做回源优化"（Range、连接复用、边缘 TLS） |
| G9 可观测与可运营 | 对象/字节/引用/命中率/GC/错误率指标；配额与滥用治理 |
| G10 渐进迁移、零数据破坏 | 旧 `mxc://` 与旧 `media://` 永远可读；不重加密、不移动旧文件、不做破坏性迁移 |

### 3.2 非目标（本阶段明确不做）

- **不修改** Matrix Server / Matrix 协议 / E2EE / 媒体上传接口 / 朋友圈 API / 数据库 schema / 客户端缓存代码（用户禁止）。
- **不实现**：全球媒体去重、CDN 改造、服务端对象迁移（用户归入 Phase 3 后半阶段）。
- **不改变**业务语义：消息格式、朋友圈可见性规则、头像刷新语义、推送载荷边界。
- **不引入**新的用户可见行为（除后续阶段批准的容量/体验改进）。
- **不做**"演绎版参数归一"（会让同一张图在不同域产生相同字节，但会改变发送字节 ⇒ 需产品评估，列 Phase 4 前的备选）。

### 3.3 设计原则（贯穿全文）

1. **E2EE 边界不可谈判**：服务端媒体平台**永远不接收、不存储、不比较 E2EE 域的明文摘要，也不接收附件密钥**（ADR-0060 §4 的边界由 Phase 3 继承并强化）。
2. **服务器只信自己算出的摘要**：客户端声明的摘要只作辅助校验，绝不作为去重键或权限依据。
3. **索引/元数据可重建，字节是唯一真相**：任何元数据表损坏都必须能从字节 + 业务表重建（与 Phase 2 的"索引是加速层"同构）。
4. **删除先解引用，回收可延迟**：绝不"删消息 = 删文件"。
5. **每个阶段可回退，且回退不丢数据**。
6. **能力优于假设**：每个设计点都写出"若不满足前提会怎样退化"。

---

## 4. MediaObject Design

### 4.1 三层拆分：Object / Blob / Variant

**【提案】** 把"媒体"拆成三层，是本设计最重要的结构决定：

```
MediaObject（逻辑实体，业务与权限的作用对象）
   │ 1
   │ n
MediaVariant（演绎版：original / thumb / 360p / poster …）
   │ n
   │ 1
MediaBlob（物理字节：storage_key + digest + 加密信封 + 大小）
```

为什么必须拆出 **Blob**：

- 去重发生在**字节**层（同一字节可被多个 object 的多个 variant 复用，例如"原图"既是 A 的 original，
  也是 B 转发后的新 object 的 original）；
- 加密信封属于**字节**（同一 blob 只有一个信封；换密钥就是另一个 blob）；
- 生命周期/回收发生在**Blob**层（引用计数归零才回收），而权限/引用发生在 Object 层；
- 未来对象存储迁移只影响 Blob 表（`storage_key`），不动业务语义。

`media_id` 与 `blob_id` 都是**服务端生成的不可猜测不透明 ID**（【提案】ULID 或 UUIDv7，便于按时间分片；
**不使用摘要作为 ID**——摘要作为 ID 会把"内容存在性"直接暴露在 URL 与日志里，见 §15.1）。

### 4.2 MediaObject 字段

```jsonc
// 【提案】MediaObject —— 逻辑实体
{
  "media_id":        "01J9Z6...",        // 服务端生成的 ULID；不透明、不可猜测、不含内容信息
  "owner_id":        "user_123",         // 上传者（用于配额与审计；不等于权限）
  "origin_domain":   "chat|moments|avatar|file|system",
  "kind":            "image|video|audio|file|gif",
  "canonical_mime":  "image/jpeg",       // canonical blob 的 mime（业务展示以引用侧元数据为准）
  "canonical_size":  1234567,
  "width": 1920, "height": 1080, "duration_ms": null,
  "digest_kind":     "plaintext_sha256_v1 | ciphertext_sha256_v1",  // ★ 见 §4.3
  "content_digest":  "…64 hex…",         // 该 kind 下的摘要（唯一索引的一部分，不是 ID）
  "encryption":      { "mode": "none|matrix_v2_envelope|deterministic_v1",
                       "key_ref": null, "iv": null },               // ★ 见 §4.4
  "status":          "uploading|ready|quarantined|orphan|collected",
  "visibility_hint": "private|audience|public",   // ★ 见 §8.4
  "ref_count":       0,                  // 缓存列（真相源是 media_references，可重算）
  "created_at": "…", "ready_at": "…", "last_access_at": "…", "collected_at": null
}
```

### 4.3 核心问题：hash 是**明文** hash 还是**密文** hash？（用户要求讨论）

**【提案】按域分离，永不混用。** 摘要在库里不是一个字段值，而是 `(digest_kind, content_digest)` 复合身份：

| 域 | 服务器可见内容 | `digest_kind` | 谁计算 | 可信性 | 隐私影响 |
| --- | --- | --- | --- | --- | --- |
| Chat（E2EE） | 仅密文 | `ciphertext_sha256_v1` | **服务器**（流式，落盘前/落盘时） | 服务器自算，可信；长度校验防截断 | 与现状一致：密文摘要 == 确定性加密下的内容指纹（§7.2 已接受的可链接性） |
| Moments / Avatar / 渲染 | 明文 | `plaintext_sha256_v1` | **服务器**（本来就有明文） | 服务器自算，可信 | 无新增泄露：服务器本来就能读取完整明文 |
| Chat（未来"原图/转发"若引入非 E2EE 通道） | 明文 | `plaintext_sha256_v1` | 服务器 | 可信 | **禁用**：一旦 E2EE 域出现明文摘要，等于给离线字典攻击提供了索引 |

强制规则（**写入设计契约**）：

1. **E2EE 域绝不出现 `plaintext_sha256_v1`**。任何"客户端送来明文摘要用于去重"的方案一律拒绝（ADR-0060 已否决，
   Phase 3 继承：`docs/adr/0060-content-addressed-media-dedup.md:被否决方案`）。
2. **服务端不接受客户端摘要作为去重键**。客户端摘要（无论是明文还是密文）只用于"校验/幂等/断点续传"，
   服务器必须自行计算权威摘要（现状已经是这样：`content_digest()` 服务端算，
   `third_party/synapse/chatflow_media_dedup.py:44-55`）。
3. **两种 kind 永不互相比较、永不共用唯一索引的同一分区**（唯一约束为 `(digest_kind, content_digest)`）。
   理由：密文摘要与明文摘要在语义上不可比，混用会产生"跨域误命中"和"通过 kind 混淆做存在性探测"。
4. **日志/指标/URL 里不出现任何摘要**（现状补丁已遵守：`chatflow_media_dedup.py:238-239`）。
5. `media_id` **不是**摘要（§4.1），因此"知道 ID"不能推出"知道内容"，"知道内容"也不能直接算出 ID。

> 关于"密文摘要是否仍属敏感"：是。**在确定性加密下，密文摘要 = 明文摘要的一个可公开计算的函数**
> （攻击者拿到候选文件即可自算并比对）。因此 `ciphertext_sha256_v1` 必须按"敏感指纹"对待：
> 不入日志、不入 URL、不通过 API 回显、仅在服务端索引内部使用，并配合 §15.1 的存在性探测缓解措施。

### 4.4 加密信息（`encryption`）字段设计

**【提案】** blob 上的信封描述（不是密钥本身）：

```jsonc
// 【提案】MediaBlob
{
  "blob_id":      "01J9Z6AB...",
  "digest_kind":  "ciphertext_sha256_v1",
  "content_digest": "…64 hex…",
  "size":         1234567,
  "mime":         "video/mp4",
  "storage_backend": "matrix_media_store | business_private_dir | s3_v1(未来)",
  "storage_key":  "…",                // 后端内部键；不对客户端暴露
  "envelope": {
     "mode": "matrix_v2_envelope",    // 或 none / deterministic_v1
     "algorithm": "AES-256-CTR",
     "key_transport": "in_event_encrypted",   // 密钥只随加密事件走，平台不持有
     "iv": "…", "sha256_ciphertext": "…"
  },
  "created_at": "…", "verified_at": "…", "unreferenced_at": null,
  "retiring": false, "quarantined_by": null
}
```

- **平台不持有密钥**：`key_transport: in_event_encrypted` 明确"密钥在 Megolm 密文内，
  媒体平台没有也不应请求它"（与 ADR-0060 §4 一致）。
- **信封与摘要绑定**：同一明文换信封（例如未来支持随机密钥）会产生新 blob（因为 `digest_kind` 从
  `ciphertext_sha256_v1` 变为不可去重的"random envelope"），这是**正确**的：随机信封下不允许跨用户去重。
  设计上用一个字段表达：`dedup_eligible: true|false`（`deterministic_v1` → true；随机信封 → false）。
  **现状已有该情形的真实例子**：Emoji 保险库附件用随机密钥加密并绕过确定性路径
  （`apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart:3141-3150`），
  因此"随机信封 + 不可去重"不是假设场景，而是已经存在的合法路径。

### 4.5 与现状的映射（迁移视角）

| 提案字段 | Matrix 侧现状 | 业务侧现状 |
| --- | --- | --- |
| `blob_id` | `chatflow_media_blobs.media_id`（随机 12 字节 hex） | 无（key 即身份） |
| `content_digest` + `digest_kind` | `chatflow_media_blobs.digest`（密文摘要） | 无（头像的 `content_hash` 可复用，但仅存在于 upload 会话行） |
| `size/mime` | `local_media_repository.media_length/media_type` | `moment_media_uploads.byte_size/mime_type`；`avatar_uploads.*` |
| `storage_key` | `media_store/<server>/<media_id>` | `*.object_key` |
| `envelope` | 事件内 `file.key/iv/hashes` | 无（无加密） |
| `status` | `retiring` + `quarantined_by` + 存在性 | upload 行 `status` |
| `ref_count` | 由 `chatflow_media_references` 可算 | 无（需从业务表反查） |

---

## 5. MediaVariant Design

### 5.1 变体类型（覆盖用户给的两组示例）

```jsonc
// 【提案】MediaVariantKind（枚举，可扩展；未知值必须被安全忽略而非报错）
// 图片
"original"          // 用户原始字节（"原图"）
"image_chat_1280"   // 聊天正文演绎版（现网 1280×1280 q80）
"image_moment_1080" // 朋友圈正文演绎版（现网 ≤1080px / ≤500KB）
"thumbnail_800"     // 聊天缩略图（现网 ≤800px / ≤100KB）
"thumbnail_small"   // 列表/头像类小图（160/240/320 档）
"preview"           // 大图查看器占位（现网 720/2048 解码约束）
// 视频
"video_360" "video_720" "video_1080"   // 转码档位（**新增能力**）
"video_compressed_chat"                // 现网聊天转码产物（640×480 / aggressive）
"preview_video"                        // 渐进播放短片（**新增能力**）
"poster"                               // 封面帧
"audio_transcoded"                     // 语音转码（未来）
```

### 5.2 变体模型

```jsonc
// 【提案】
{
  "variant_id":   "01J9Z6V...",
  "media_id":     "01J9Z6...",          // 所属逻辑对象
  "kind":         "video_720",
  "blob_id":      "01J9Z6B...",         // ★ 指向物理字节（可与其他 variant 共享）
  "status":       "pending|processing|ready|failed|skipped",
  "mime":         "video/mp4",
  "codec":        "h264|aac|vp9|av1|jpeg|webp|gif",
  "width": 1280, "height": 720,
  "bitrate_bps":  2200000,
  "duration_ms":  45000,
  "size":         12000000,
  "generation":   2,                    // 转码器/参数版本；参数升级产生新 generation
  "derived_from": "original",           // 族谱：由哪个 variant 产出
  "created_at": "…", "ready_at": "…",
  "is_primary":   true                  // 该 kind 的默认档（同 kind 多 generation 时取最新 ready）
}
```

### 5.3 关键设计点

1. **Variant 不是新的"媒体实体"**：它不拥有权限、不拥有引用（权限/引用都挂在 `media_id` 上），
   只拥有"字节 + 编码元数据 + 就绪状态"。这样"朋友圈引用了这条视频的 720p"与"聊天引用了它的 poster"
   不会分裂成两个权限世界。
2. **Blob 级去重跨越 variant 与 object**：`media_variants.blob_id` 上的唯一索引 + blob 的
   `(digest_kind, content_digest)` 唯一约束，使"同一张缩略图被 1 万个 object 复用"只占一份字节。
3. **族谱与 generation**：转码参数升级（例如 720p 码率从 1.5M 提到 2.2M）**不覆盖**旧 variant，
   写新的 `generation`；读取默认取 `is_primary` 的最新 ready，客户端缓存键包含 `generation`
   （与 Phase 2 本地索引的 `family_id`/`verified_at` 语义兼容）。
4. **失败必须显式**：`status = failed` + `failure_reason`（枚举，不含内容），UI 才能正确降级
   （现网 Phase 1 的 `VideoPosterSource.placeholder` 是同一思路）。
5. **`skipped` 与"不适用"**：例如 GIF 没有缩略图（客户端审计 §1.4）、短视频不生成 1080p
   （源分辨率不够）——必须显式记录，否则客户端会无限重试。
6. **不做"视觉相似"归并**：同一张图的不同压缩参数是**不同 blob**（现网 Phase 2 已固化该语义：
   q80 与 q70 = 2 个对象，`apps/mobile_flutter/test/features/matrix/media_index_phase2_test.dart`）。
7. **变体选择策略属于服务端可配置策略**（`MediaCodecPolicy` 的服务端对应物），
   【提案】读取端可用 `?prefer=auto|data_saver|quality`，但**不改变**发送端字节。

### 5.4 视频能力（用户 §14：Telegram 级）

```
上传的原片（original）
   │  【提案】转码流水线（异步、可重试、幂等，输入 blob_id + generation）
   ├─▶ 探测：容器/编码/时长/分辨率/旋转/音轨（容器级探测，不解码全片）
   ├─▶ poster         （最优先，先于任何转码产物就绪；用于列表首屏）
   ├─▶ preview_video  （≤3s、≤360p、无音轨或有音轨；用于渐进播放的第一段）
   ├─▶ video_360 / video_720 / video_1080（按源分辨率裁剪候选档，不做上采样）
   └─▶ 结论写回 media_variants；失败重试上限后置 failed（客户端降级到下一档）
```

**Progressive Loading（用户要求）**：

```
t0  客户端拿 poster（几百 KB，通常已缓存在 CDN 边缘）      → 秒显封面
t1  播放 preview_video（≤3s 短片，可立即起播）             → "看得见在播"
t2  切到 video_360/720（Range 或独立变体文件，边下边播）    → 清晰度按网络自适应
t3  后台继续缓存 video_1080/原片（用户主动"查看原片"或 WiFi）
```

前提与代价（必须写明）：

- 现有客户端是"整文件下载+解密+落盘后 `VideoPlayerController.file`"（客户端审计 `:114`），
  所以**渐进播放需要客户端改造**（不在本阶段范围）。服务端只负责"变体存在且可 Range 读取"。
- E2EE 视频的 preview/转码产物**不能由服务端生成**（服务端没有明文，也没有密钥）。
  【提案】E2EE 域的 preview 只能**由发送端生成并加密上传**（发送端已有转码能力），
  或由"持有密钥的接收端"在本地生成（Phase 4 备选）。
  这是 E2EE 下"Telegram 级视频体验"的**根本约束**，必须在产品层明确。
- 明文域（Moments/Avatar/File 未来）的转码可由服务端直接做。

---

## 6. MediaReference Design

### 6.1 引用模型

```jsonc
// 【提案】
{
  "reference_id":     "01J9Z6R...",
  "media_id":         "01J9Z6...",
  "variant_kind":     "image_chat_1280",   // null = 不关心档位（跟随 media 主档）
  "business_type":    "chat_message|group_message|moment|moment_comment|moment_cover|avatar|announcement|file|system",
  "business_id":      "$eventId 或 moment_5 或 user_9",
  "business_scope":   { "room_id": "!room:server", "seq": 12345 },  // 便于按房间/时间清理
  "ref_kind":         "observed|declared",     // ★ 见 §6.3
  "state":            "active|released",
  "created_at": "…", "released_at": null,
  "release_reason":   null   // message_deleted|moment_deleted|avatar_replaced|retention|user_delete|moderation
}
```

### 6.2 引用计数

- `ref_count(media_id)` = `count(references where state='active')`。
- **缓存列 + 定期对账**：`media_objects.ref_count` 是可重建的缓存；对账任务从 `media_references`
  重算并修正（与 Phase 2 的"引用数必须能从 `refs/*.ref` 重算"同一原则）。
- 归零**不等于**立即回收：还要过 `unreferenced_at + grace`（保留期，见 §9.3），
  因为"引用写入"可能滞后于"字节上传"（崩溃窗口，现状补丁用 `pending` 表处理同一个问题：
  `third_party/synapse/chatflow_media_dedup.py:70-78,213-223`）。

### 6.3 E2EE 的根本矛盾（必须诚实回答）

**服务器无法从 E2EE 事件中看到"某条消息引用了某个媒体"，也无法数出消息条数**
（现状补丁的 README 已经承认：`third_party/synapse/README.md:37-38`）。因此引用体系必须分两级：

| 级别 | 语义 | 来源 | 可否用于回收 |
| --- | --- | --- | --- |
| `observed` | 服务器**能观测**的引用（上传者引用、非 E2EE 域的业务行） | 上传、业务表 | **可以**（现状的 `chatflow_media_references` 就是这一类） |
| `declared` | 客户端（或业务服务）**声明**的引用（"这个消息引用了这台媒体"） | 需新增的声明接口 | **仅作为提示**，不能单独决定删除 |

**【提案】保守策略（默认）**：

1. E2EE 域的回收依据**仍是 observed 引用 + 保留期下限**（例如 `max(grace, E2EE_retention_floor)`，
   【提案】默认 30 天），**不因缺少 declared 引用而提前回收**。
2. `declared` 引用用于**优化**（例如 last_access 触达、配额计费口径、
   "我的媒体"列表完整性），并允许显式 `release` 以加速回收；
   但**删除决策必须同时满足**：`observed_ref_count == 0` **且** `declared_ref_count == 0`
   **且** 超过保留期下限。
3. 防滥用：`declared release` 只能作用于**自己的**引用（subject 必须是引用创建者），
   杜绝"恶意客户端的 release 让别人的 blob 被回收"（现状补丁按 `(media_id,user_id)` 隔离正是同一动机）。
4. **绝不用"引用数"冒充"消息数"**（现状已经明确不这么做）。

### 6.4 与现状的映射

| 现状 | 映射到 | 迁移动作（Phase B/C） |
| --- | --- | --- |
| `chatflow_media_references(media_id,user_id)` | `references` with `business_type='uploader'`, `ref_kind='observed'` | 仅建立视图/适配，**不搬数据** |
| `moments.image_urls` / `moment_comments.image_object_keys` | 每个 key → 一条 `business_type='moment'|'moment_comment'` 引用 | 惰性回填（首次访问或后台批处理） |
| `moments_preferences.cover_object_key` | `business_type='moment_cover'` | 同上 |
| `users.avatar_object_key` | `business_type='avatar'` | 同上 |
| Matrix 事件里的 `mxc://`（含 `chatflow_media` 扩展） | 仍由客户端/事件承载；服务端**不解析加密事件** | 不迁移（保持 E2EE 边界） |

---

## 7. Encryption Dedup Analysis

> 用户要求：分析方案 A / B / C，**不选型**（"不要选择，只做技术分析"）。
> 本节给出技术分析、判定维度、与现状的关系，并把**选型**留在 §7.6（需产品/隐私评审的开放决策）。

### 7.1 前提：ChatFlow 今天的加密形态

- 附件加密是**确定性**的：`H = SHA-256(明文)` → `HKDF(H, salt="chatflow-media-v1", info="aes-256-ctr-v1")`
  → `key = OKM[0:32]`、`IV = OKM[32:40] + 8 个零字节`（64 位 nonce + 64 位零计数器）
  → AES-256-CTR（`docs/adr/0060-content-addressed-media-dedup.md:11`）。
- 也就是说：**相同明文 ⇒ 相同密钥 ⇒ 相同 IV ⇒ 完全相同密文**。
- 服务器只看到密文与密文摘要，从未看到明文或明文摘要（`docs/adr/0060-content-addressed-media-dedup.md:17`）。
- 现行服务端去重就是"密文摘要 → 共享 media_id"（`third_party/synapse/chatflow_media_dedup.py:191-240`）。

**结论（对分析至关重要）**：ChatFlow **已经在跑**"确定性加密 + 服务端按密文摘要去重"，
即**方案 B 在确定性加密前提下的形态**（这也正是 convergent encryption 家族）。因此本节的
"方案 B"分析不是假设，而是现状的形式化；A 与 C 是**替代或补充**路径。

### 7.2 方案 A：客户端计算 `SHA256(original)`，上传 `media_hash`，服务器按 hash 查重

```
Client: H = SHA256(明文)  ──上传参数/事件字段──▶  Server: lookup(H) → 复用 blob
```

| 维度 | 分析 |
| --- | --- |
| 去重能力 | **最强**：跨用户、跨设备、跨密钥（即使未来改用随机信封也能命中）；跨域（明文域与 E2EE 域）**仍不行**，因为域间演绎版字节不同 |
| 隐私 | **最差**：把一个**可直接离线字典攻击的明文指纹**交给了服务器。服务器（或入侵者/内鬼/传票）可以：① 对候选文件集（例如某泄露库）批量算 H 做**存在性探测**；② 建立"谁上传过这个文件"的关联图；③ 一旦泄露，等于泄露"用户拥有该文件"的证据。**ADR-0060 已明确否决这条路**（"将明文哈希交服务器违反主动暴露边界"） |
| 与 E2EE 边界 | **冲突**：E2EE 的意义是服务器不知道内容；提交明文指纹等于让服务器获得内容的可验证指纹 |
| 实现代价 | 低（客户端已有 `sha256(bytes)`；服务端复用现有摘要索引，只需扩展 `digest_kind`） |
| 抗滥用 | 存在性探测接口天然成为"内容发现 API"，需要额外限流/审计（但仍然无法消除信息泄露） |
| **适用场景（若强行采用）** | 只适用于**服务器本来就持有明文**的域（Moments/Avatar）——但那正是"服务器自己就能算"的情形，**没有必要让客户端提交**（见 §4.3 规则 2） |

**结论**：对 E2EE 域，方案 A 在隐私上是**净负面**且可由 §7.3 的方案 B 在**不增加泄露**的前提下替代；
对明文域，A 是"无必要的信任外部输入"。**不建议在任何域采用 A。**（保持为"被否决方案"。）

### 7.3 方案 B：hash encrypted object（对密文做摘要）

```
Server: 接收密文流 → 流式 SHA256(密文) → 查重 → 复用 blob
（客户端不上传任何摘要；服务器自己算）
```

| 维度 | 分析 |
| --- | --- |
| 为什么"不同 nonce ⇒ same file ≠ same ciphertext" | 若信封**随机**（随机 key 或随机 IV），相同明文的两次加密产生不同密文 ⇒ 密文摘要不同 ⇒ **去重完全失效**。这是方案 B 的**唯一但致命的**前提依赖 |
| 在 ChatFlow 的确切表现 | 因为加密是**确定性**的（§7.1），"相同明文 ⇒ 相同密文"成立 ⇒ **方案 B 有效**，且与现状一致 |
| 隐私 | 密文摘要 **等价于** 明文摘要的"可计算函数"：攻击者若拿到候选文件，可自行按同一确定性方案加密并比对，从而**确认**服务器上是否存在该文件。因此方案 B **不消除**字典/存在性探测风险，只是**不把指纹直接交给**服务器（服务器仍可自行获得同一指纹，但需要先有候选文件与同一算法） |
| 与 E2EE 边界 | **兼容**：服务器只处理它本来就收到的密文；不需要客户端额外交出任何关于明文的可验证信息 |
| 跨用户去重 | ✅（现状已实现，含并发/崩溃/隔离语义） |
| 跨域去重 | ❌ 明文域是明文、E2EE 域是密文，`digest_kind` 不同 ⇒ 永不相遇（这是设计上**故意**的：避免把明文域与密文域混在一个索引里做存在性推理） |
| 关键脆弱点 1：信封随机化 | 一旦未来关闭确定性加密（`deterministicMediaEncryption=false`，现状是可选开关）⇒ 去重率归零，且**已产生的映射必须保留可读**（现状补丁已处理：关闭开关不删映射，`third_party/synapse/README.md:64-70`） |
| 关键脆弱点 2：算法版本 | 若派生算法版本变化（`v=2`），同一明文的密文变化 ⇒ 老 blob 不再被命中。设计上必须把**算法版本**纳入身份：`(digest_kind, envelope_version, content_digest)`，或更简单——**算法升级即视为不同 blob 家族**，允许并存（不追删旧 blob） |
| 关键脆弱点 3：CTR 计数器与分片 | 确定性 CTR 的 IV 含"初始计数器 0"（`docs/adr/0060-content-addressed-media-dedup.md:11`）。若未来做分片上传并在客户端并行加密分片，必须保证**每片的计数器起点 = 全局字节偏移 / 16**，否则密文不同 ⇒ 去重失效。这是分片上传设计（§10.4）的硬约束 |
| 实现代价 | 已有（Matrix 侧）；业务域若要复用，只需服务器自算明文摘要（更简单） |

**结论**：方案 B 是**当前形态的形式化**，与 E2EE 边界兼容，且不新增"客户端交出指纹"的暴露面；
其隐私强度**依赖确定性加密已接受的可链接性**（ADR-0060 明确记录用户已接受该风险）。
**推荐方向（非本阶段结论）**：E2EE 域维持 B；明文域用"服务器自算明文摘要"（B 的明文版）。

### 7.4 方案 C：blind dedup / convergent encryption / salted hash / trusted service

> 用户要求：只做技术分析，**不要选择**。

**(C1) Convergent encryption（收敛加密）**
- 机制：`key = H(明文)`（或 `H(明文) 的派生`），因此相同明文产生相同密文，服务器可按密文去重。
- **ChatFlow 现状就是 C1 的一个实例**（HKDF 域分离版本）：确定性 key 派生 = 收敛加密。
- 优点：服务端零知识去重、无需客户端交出指纹、实现已在跑。
- 缺点（学术界与工业界的既有结论，均适用于 ChatFlow）：① **确认攻击/字典攻击**（attacker 有候选文件即可确认存在于服务器）；② **文件长度的可观察性**；③ 需要"何时允许去重"的策略（例如小于 x 字节或热度不足的文件**禁止**去重，以对抗"针对特定小文件的确认攻击"）；④ 密钥泄露即内容泄露（ChatFlow 的密钥在 Megolm 密文内，风险等同消息泄露）。
- 缓解手段（技术分析，不含选型）：**去重门槛**（`size >= threshold` 或"同一摘要出现 ≥ N 次才允许复用"）、
  **随机化映射**（摘要 → 加盐后再索引）、**审计与限流**（限制存在性探测速率）。

**(C2) Salted hash / keyed hash（服务端密钥参与的摘要）**
- 机制：`index_key = HMAC(server_secret, digest)`，服务器数据库泄露时摘要不可离线穷举
  （因为攻击者缺 `server_secret`）。
- 优点：**显著提高"数据库泄露"场景下的隐私**；对在线确认攻击无效（服务器仍可应答"存在/不存在"）。
- 缺点：`server_secret` 成为**新的关键资产**（轮换会导致索引重建/去重断裂）；多区域/多实例需要共享密钥；
  仍不能阻止"有查询权限者"做在线探测。
- 与现状：可用作**索引层的附加保护**（把 `digest` 列替换为 HMAC 值），字节层不变。

**(C3) Trusted service / 盲去重（blind dedup）**
- 机制：把"存在性查询"与"上传/下载"分离，由一个**受审计的独立服务**（或 MPC/OPRF 协议）判定，
  平台本身不持有可离线穷举的指纹；查询结果只返回"是否需要上传"与一个一次性取件凭据。
- 优点：设计上最接近"既能去重、又不给平台一个可用于确认攻击的指纹库"；
  可以把"谁能查询、查多少次"做成显式的审计与配额。
- 缺点：**复杂度最高**（新服务 + 新协议 + 新故障域 + 新审计面）；OPRF/盲签名类方案的工程成熟度与
  延迟代价需要实测；仍然是"在线预言机"（有权限者仍可探测，只是被审计与限速）。
- 与现状：现状补丁的"摘要锁 + 引用表 + 隔离墓碑"是 C3 的**简化形态**（把受信任逻辑放在 Synapse 内部，未独立）。

**(C4) 其他被提及的做法**
- "不提供去重"（每次上传独立 blob）：隐私最好、成本最高（现状的 Moments/Avatar 就是这种，属于**被动选择**）。
- "本地去重 + 服务端不做"：无法跨用户省存储。

### 7.5 方案对照表

| 维度 | A 明文哈希给服务器 | B 密文摘要（现状） | C1 收敛加密 | C2 加盐/HMAC 索引 | C3 受信盲去重 |
| --- | --- | --- | --- | --- | --- |
| 跨用户去重 | ✅ | ✅（需确定性信封） | ✅ | ✅ | ✅ |
| 客户端交出明文指纹 | **是（不可接受）** | 否 | 否（但等价可算） | 否 | 否 |
| 服务端可从字节自算指纹 | — | ✅（它就看到密文） | ✅ | ✅ | ✅（但被 HMAC 遮蔽） |
| 抗离线字典（DB 泄露） | ❌ | ❌（等价） | ❌ | **✅**（需 secret 未泄露） | **✅**（指纹不在平台） |
| 抗在线存在性探测 | ❌ | ❌（有 dedup 应答） | ❌ | ❌ | 部分（限速+审计+可拒绝） |
| 与 E2EE 边界 | **冲突** | 兼容 | 兼容 | 兼容 | 兼容 |
| 工程复杂度 | 低 | **已有** | 已有 | 中（密钥生命周期） | 高（新服务/协议） |
| 跨域（明文↔密文）去重 | ❌ | ❌（kind 隔离） | ❌ | ❌ | ❌ |
| 现状落地度 | 未采用（ADR 否决） | **已生产** | 已生产（形式等价） | 未采用 | 未采用（有简化形态） |

### 7.6 本阶段的处理方式（不选型）

**【提案 / 开放决策】** 本阶段**不选型**，只登记判定维度与后续所需评审：

1. 现有 E2EE 形态（确定性加密 + 密文摘要）**保持不变**；Phase 3 只把它**形式化**为
   `digest_kind = ciphertext_sha256_v1` 并用 `envelope_version` 显式表达算法版本。
2. 明文域（Moments/Avatar/渲染）**由服务器自算明文摘要**——这是"方案 B 的明文版"，
   不需要客户端提交任何指纹（也**不允许**客户端提交指纹作为去重键，§4.3）。
3. 是否引入 C2（HMAC 索引）或 C3（受信盲去重）**需要产品 + 隐私 + 安全评审**，
   并明确回答：可接受的在线确认攻击面、去重门槛、审计与限流强度、密钥轮换的索引重建成本。
4. **无论选哪条**，以下不变量不变：
   - 服务端不接收 E2EE 明文摘要 / 密钥；
   - `media_id` 不是摘要；
   - 摘要不入日志/URL/API 回显；
   - 去重必须"可关闭"且关掉后**不丢数据、不破坏可读性**（现状已满足）。
5. 去重门槛（"多大/多热才允许去重"）属于**策略**而非架构，【提案】放在
   `MediaDedupPolicy`（服务端配置）中，默认：`size >= 256 KiB` 且 `envelope == deterministic_v1`；
   小文件默认**不跨用户去重**（对抗针对小文件的确认攻击）。

---

## 8. Permission Model

### 8.1 用用户给的例子驱动设计

> 用户 A 上传图片 → A 在聊天发送 → A 在朋友圈发布 → 用户 B 收到聊天。谁可以访问？

**【提案】访问判定 = "对象/变体 × subject × permission × 业务授权"，其中业务授权是主要来源**：

| 请求者 | 请求 | 判定 | 依据 |
| --- | --- | --- | --- |
| A（上传者/owner） | 任何自己对象的任何变体 | **允许** | `subject == owner_id` |
| B（同房间成员） | 聊天里那条消息引用的**聊天演绎版**（或 poster/缩略图） | **允许** | 引用 `business_type='chat_message'` + Room 成员资格（由 Matrix 授权实时判定） |
| B | 该 `media_id` 的**原图**（A 从未在聊天里发过原图） | **拒绝**（默认） | 变体级授权：`business` 授权只覆盖"被引用的变体集合" |
| B | A 的朋友圈演绎版 | **拒绝**（除非朋友圈可见性允许 B 查看该动态） | Moments 可见性策略（`VisibilityPolicy.can_view`） |
| C（无关用户） | 任何变体 | **拒绝** | 无任何 grant |
| 被移出房间的 B | 该消息的变体 | **拒绝**（新请求） | 实时成员资格复核；已签发的短 TTL 令牌在 TTL 内仍有效（明确记录该窗口，§15.4） |
| A 撤销/删除消息 | — | 引用 `released`，不删对象（§9.3） | 引用式删除 |

### 8.2 Access Grant 模型

```jsonc
// 【提案】media_access_grants
{
  "grant_id":     "01J9Z6G...",
  "media_id":     "01J9Z6...",
  "variant_scope": ["image_chat_1280", "thumbnail_800", "poster"],  // 或 "*"（仅 owner/管理员）
  "subject_type": "user|room|audience|public|service",
  "subject_id":   "user_456 | !room:server | moment_audience(moment_5) | * | business-api",
  "permission":   "read|read_original|list|delete|admin",
  "derived_from": { "rule": "room_membership|moment_visibility|owner|admin",
                    "ref": "!room:server | moment_5 | user_456" },  // ★ 授权推导来源，可实时复核
  "expires_at":   "…",       // 服务端强制；**不接受客户端指定**
  "single_use":   false,
  "issued_by":    "system|user_123|admin_7",
  "revoked_at":   null, "revoke_reason": null,
  "created_at":   "…"
}
```

### 8.3 判定算法（【提案】，顺序即优先级）

```
authorize(request):
  1. 规范化：media_id → object；确定请求的 variant 与 permission
  2. owner / admin 短路允许（仍记录审计）
  3. 显式 grant 匹配（subject + variant_scope + permission + not expired + not revoked + not single-use 已用）
  4. 业务规则推导（derived_from.rule）：
       room_membership  → 实时向 Matrix 授权层确认请求者仍是该房间成员且事件仍可见
       moment_visibility→ 实时调用 Moments 可见性策略
       public           → 仅对 visibility_hint=public 的对象（例如头像版本化 URL）
  5. 若 3/4 都不成立 → 拒绝（默认拒绝，fail-closed）
  6. 无论允许或拒绝，都写审计（不含摘要/不含 URL 令牌明文）
```

关键设计点：

- **默认拒绝（fail-closed）**：任何策略异常（Matrix 不可达、Moments 查询失败）→ 拒绝并返回可重试错误，
  绝不"降级为允许"。
- **推导式授权优先于快照式授权**：成员资格/可见性是**实时**的，不写"永久快照"，
  因此"退群/删除动态/拉黑"能立即生效（现状 Moments 已经这样：`media_access.py:76-79`；
  Matrix 侧由 access token + 房间状态保证）。
- **变体级授权**：`variant_scope` 让"B 能看缩略图但不能看原图"成为一等公民
  （现状做不到：`mxc://` 一旦拿到就能读该附件；聊天里正文与缩略图是两个附件，天然近似于该语义）。
- **令牌与 Grant 分离**：Grant 是**服务端真值**；令牌（URL 里的签名）只是 Grant 的**证明**，
  必须绑定 viewer/用途/过期/次数（§11.3），且**过期时间由服务端写死在令牌里**，
  不接受客户端查询参数（修正审计发现 A13）。
- **单次/短时令牌**：`single_use` 用于高敏感（原图、证件、金融凭证类附件）。
- **授权缓存**：允许服务端在**极短 TTL**（【提案】≤5s）内缓存判定结果以抗热点；
  撤销通道（revocation）必须能让缓存失效（Redis pub/sub 或版本号）。

### 8.4 可见性分级（`visibility_hint`）

| 级别 | 含义 | 缓存/CDN 策略 | 例子 |
| --- | --- | --- | --- |
| `private` | 仅 owner/显式 grant | 不回 CDN 缓存；短 TTL 签名；可单次 | 聊天附件（E2EE）、原图、闪照 |
| `audience` | 某受众集合内共享（房间/好友/动态可见者） | **受众级签名 URL**（同一受众同一 URL，缓存命中率高） | 群聊附件、朋友圈图片 |
| `public` | 无差别可读（仍需不可猜测 URL） | 可长 TTL + 公共缓存 + CDN | 头像（版本化 URL）、公开封面 |

> 注意：`visibility_hint` 是**策略输入**而不是权限本身；它只影响缓存与令牌策略，
> 最终判定仍走 §8.3。

---

## 9. Lifecycle

### 9.1 三条主流程（用户要求的三段状态机）

**Upload**

```
[client] create session ──▶ media_objects(status=uploading) + media_upload_sessions(created)
        │
        ├─ 上传分片（可并发/可暂停/可续传）→ sessions.uploaded_parts 累积
        ├─ 校验：每片摘要（客户端声明，仅校验用）+ 服务端自算权威摘要
        ├─ complete（幂等）→ 服务端组装/校验 → Blob 落盘 → 摘要索引登记
        │                    → media_objects.status=ready + 默认 variants 入队
        └─ abort / 过期 → 清理临时分片，session=expired（**可回收**）
```

**Read**

```
[client] GET variant ──▶ authorize(§8.3) ──▶ 选档（prefer 策略）
        │                                   ├─ ready 变体 → 签发令牌/302 CDN
        │                                   ├─ 只有 poster → 先给 poster（渐进）
        │                                   └─ 无 ready 变体 → 202 + 转码进度（或占位）
        └─▶ 边缘/CDN → 客户端（Range 支持）→ 客户端本地缓存（Phase 2 的索引/配额）
        last_access_at 更新（批量去抖，禁止每请求一次写）
```

**Delete**

```
[caller] release reference（业务删除/撤回/替换）
        │
        ├─ references.state=released（**不删字节**）
        ├─ 若 observed+declared 引用均归零 → objects.unreferenced_at = now
        ├─ 保留期（grace / E2EE floor）内**仍可复用**（重传命中同一 blob）
        └─ 到期 → GC 候选 → 标记 retiring（先索引后 unlink）→ 删除 blob + 变体行
                    失败 → 保持可恢复状态（绝不"假成功"）
```

### 9.2 显式状态机

| 实体 | 状态 | 迁移触发 |
| --- | --- | --- |
| `media_objects` | `uploading → ready → orphan → collected`；`ready → quarantined`；`quarantined → ready`（显式解除） | 上传完成 / 引用归零 / 保留期到期 / 管理员隔离 |
| `media_blobs` | `staged → verified → active → retiring → deleted` | 落盘 / 摘要校验 / 发布 / GC / unlink |
| `media_variants` | `pending → processing → ready`；`→ failed`；`→ skipped` | 入队 / 转码 / 完成 / 失败 / 不适用 |
| `media_upload_sessions` | `created → uploading → verifying → committed`；`→ aborted/expired` | 客户端行为 + 超时 |
| `media_access_grants` | `active → expired/revoked` | 时间 / 显式撤销 |
| `media_references` | `active → released` | 业务事件 |

**强制规则**：① 状态只能沿箭头走（不可逆迁移必须走新实体）；② 每次迁移写审计
（`from/to/actor/reason`，**不含摘要/内容**）；③ 任何"半路崩溃"必须能靠状态字段恢复
（与现状补丁 `pending`/`retiring` 的恢复思路一致：`third_party/synapse/chatflow_media_dedup.py:177-190,224-237`）。

### 9.3 回收策略

| 参数 | 【提案】默认 | 理由 |
| --- | --- | --- |
| `grace_period` | 7 天（沿用 `CHATFLOW_MEDIA_RETENTION_MS` 现状默认） | 与现状一致；覆盖"引用写入滞后"窗口 |
| `e2ee_retention_floor` | 30 天 | E2EE 域引用不可数 ⇒ 下线不能太激进；宁可多留 |
| `e2ee_last_access_extension` | 每次真实读取可延长（上限 180 天） | 热媒体不该被"上传者引用"误回收（现状 Matrix 有 `last_access_ts`） |
| 小文件/低热度 | 不跨用户去重（§7.6） | 对抗确认攻击 |
| GC 并发 | 【提案】单飞 + 限速（每轮最多 N 个对象、可中断） | 避免 GC 变成 IO 风暴 |
| GC 保护 | 有 `active` 引用 / 未到期保留 / `retiring` 未完成 / 有活跃上传会话 / 被 pin（转码中、下载中） | **绝不删除正在使用的字节**（与 Phase 2 的 pin/lease 同构） |
| Dry-run 与审计 | 每次 GC 可 dry-run，输出"将删除清单"；真删必须留审计 | 可运营、可追责 |

---

## 10. Upload Protocol

### 10.1 现状（作为对照）

单次请求：`POST /_matrix/media/v3/upload`（≤50 MiB，无分片，无续传）
或业务侧 begin/put/complete（≤20 MiB 图片，无分片）。**1GB+ 视频在现状下不可能上传。**

客户端侧的具体障碍（本次审计确认，决定了新协议必须"补什么"）：

| 客户端现状 | 对新协议的硬要求 |
| --- | --- |
| **完全没有可续传上传**（无 `Content-Range`/resumable 用法；SDK 生成了 `/_matrix/media/v1/create` 但无调用者） | 续传必须从零建立，且要能在"应用被杀/切换网络"后恢复 |
| 失败 = **整请求重试**，固定 1 s 间隔，受 60 s（Matrix）/20 s（业务 API）总时限约束 | 必须让"补缺失分片"取代"整段重来"，否则 1 GB 文件永远传不完 |
| 媒体发送并发 = 3（信号量） | 分片并发应由服务端下发上限并与客户端信号量协同，避免 3 × N 个连接打满弱网 |
| 上传前去重 = 无 | 服务端去重是唯一去重层；客户端不需要新增"查询是否已存在"的接口（也是隐私上的刻意选择，§7.3） |
| 客户端有"随机信封"路径（Emoji 保险库 `MatrixFile.encrypt()`） | 协议必须允许 `dedup_eligible=false` 的对象存在且不被去重逻辑影响 |

### 10.2 【提案】统一上传协议（会话式）

```http
POST /media/v1/uploads
     Authorization: Bearer <token>
     Idempotency-Key: <uuid>
     { "kind":"video", "size": 2147483648, "mime":"video/mp4",
       "digest_claim": { "kind":"plaintext_sha256_v1", "value":"…" } | null,   // 仅明文域允许
       "envelope": { "mode":"deterministic_v1", "version":1 } | { "mode":"none" },
       "origin_domain":"chat", "variant_intent":["poster","video_720","preview_video"] }
  → 201 { "upload_id":"…", "part_size": 8388608, "expires_at":"…",
          "existing_media_id": "…" | null }        // ★ existing 仅在服务端确认可复用时返回

PUT  /media/v1/uploads/{upload_id}/parts/{part_number}
     Idempotency-Key: <uuid>                       // 分片级幂等
     Content-Length: <part_size>
     <bytes>
  → 204 { "etag":"part-digest" }

GET  /media/v1/uploads/{upload_id}
  → 200 { "parts":[{"n":1,"size":…,"etag":"…"}], "status":"uploading|verifying|committed" }   // 续传

POST /media/v1/uploads/{upload_id}/complete
     Idempotency-Key: <uuid>
     { "parts":[{"n":1,"etag":"…"}, …], "digest_claim": {…}|null }
  → 200 { "media_id":"…", "variants":[{"kind":"poster","status":"pending"}, …] }
  → 409 { "code":"PART_MISSING|DIGEST_MISMATCH|SESSION_EXPIRED" }

DELETE /media/v1/uploads/{upload_id}               // abort：删除临时分片
  → 204
```

### 10.3 设计要点（逐条给出理由与退化行为）

| 要点 | 设计 | 理由 / 退化 |
| --- | --- | --- |
| 分片大小 | 【提案】8 MiB 默认，服务端在 create 时下发；允许 1–64 MiB 协商 | 兼容 nginx `client_max_body_size`；便于并行 |
| 幂等 | `Idempotency-Key` 在 create 与 complete 都必须；分片 PUT 幂等（同 n 覆盖同 etag 或返回 409） | 弱网重试是常态（现状业务侧已用 Idempotency-Key，可复用该模式） |
| 续传 | `GET upload` 返回已收分片；客户端只补缺失片 | 现状完全没有；这是 1GB+ 的**前提** |
| 校验 | 每片 etag（服务端自算）+ 全局权威摘要（服务端在组装时自算） | 客户端 `digest_claim` **只用于**提前发现错误与幂等，**不作为去重键**（§4.3） |
| 去重时机 | **只在 complete 之后、以服务端自算摘要查重**（服务端仍需接收全部字节）。**不提供**"仅用摘要查询是否存在"的客户端预检接口 | 预检接口会把"存在性探测"变成一个廉价 API（§7.3 隐私分析）；现状也没有该接口，保持一致 |
| E2EE 与分片 | 客户端**先加密再分片**；确定性 CTR 下分片必须保持计数器连续性（第 k 片的首块计数器 = 全局偏移/16） | 否则密文与"单次上传"结果不同 ⇒ 破坏跨用户去重（§7.3 脆弱点 3）。**【提案】客户端实现上更稳的做法：整文件流式加密，分片只切"密文流"** |
| 大文件与 E2EE 内存 | 流式：读一段 → 加密 → 上传一片（恒定内存） | 现状客户端是整文件进内存/整文件下载（客户端审计 §2.1），大文件会 OOM |
| 后台续传 | 服务端只保证"会话可续 + 幂等"；客户端负责后台队列与重试（现状已有账户级 outgoing 队列：`matrix_e2ee_client.dart:4646,4715`） | 服务端不应假设客户端在线 |
| 会话 TTL | 【提案】24 小时（大文件）内可续；过期自动 abort 并可回收 | 过短会让 1GB+ 在弱网下失败；过长会攒垃圾 |
| 上限 | 【提案】单文件 2 GiB（可配置），单用户并发会话数与在途字节配额 | 当前 50 MiB 是硬伤（§4.2 审计），需与 nginx/Synapse 上限一起调整（部署变更，非本阶段） |
| Matrix 兼容 | 现有 `POST /_matrix/media/v3/upload` **保留**（不删除）；大文件走新协议后，事件里仍写 `mxc://` | "不修改 Matrix 协议"约束下，新协议是**并行**通道（§14 Phase A/B） |

### 10.4 与现状并存的兼容矩阵

| 场景 | 现状路径 | Phase B 起的新路径 | 兼容要求 |
| --- | --- | --- | --- |
| 小图聊天发送 | `sendFileEvent` | 可继续走现状（**不变**） | 旧客户端永久可用 |
| 大视频（>50MiB） | 不可用 | 新分片协议 → blob → 事件里写 `mxc://`（引用同一 blob） | 服务端需能把"新协议产出的 blob"映射为可被 `mxc://` 读取的媒体（§14 Phase B 的对接点） |
| 朋友圈/头像 | begin/put/complete | 同一新协议（会话式，逻辑等价） | 旧客户端与旧接口保留至 Phase D |
| 转码产物 | 客户端转码后上传 | 服务端转码（明文域）/ 客户端转码（E2EE 域） | E2EE 域**必须**仍是客户端转码（服务端无密钥） |

---

## 11. Download Protocol

### 11.1 【提案】统一下载

```http
# 1) 元数据（可选，用于选档与渐进播放）
GET /media/v1/objects/{media_id}
  → 200 { "kind":"video", "variants":[{"kind":"poster","status":"ready","size":…},
                                      {"kind":"video_720","status":"ready","size":…},
                                      {"kind":"video_1080","status":"processing"}],
          "access":{"can_read":true,"can_read_original":false,"expires_at":"…"} }

# 2) 取字节（两种返回风格，二选一由服务端策略决定）
GET /media/v1/objects/{media_id}/variants/{kind}
  → 302 Location: <signed CDN URL>            # 可缓存内容（audience/public）
  → 200 <bytes>                               # 不可缓存内容（private，边缘不缓存）
  → 206 <partial bytes>                       # Range 请求（视频必用）
  → 202 { "status":"processing", "retry_after_ms": 800 }   # 变体未就绪（客户端可回退到 poster/低档）

# 3) 令牌刷新（长会话/播放中）
POST /media/v1/objects/{media_id}/tokens
     { "variant":"video_720", "purpose":"playback" }
  → 200 { "url":"…", "expires_at":"…" }        # 服务端强制 TTL；不接受客户端指定（修正 A13）
```

### 11.2 响应头契约（【提案】）

| 头 | 值 | 目的 |
| --- | --- | --- |
| `Cache-Control` | `private, no-store`（private）/ `private, max-age=<ttl>`（audience，允许 CDN 按 URL 缓存）/ `public, max-age=<ttl>, immutable`（public，URL 含版本） | 与 §8.4 分级一致；**不再"一律 no-store"**（现状审计 §4.3） |
| `ETag` | blob 摘要的**加盐**派生值（例如 HMAC(secret, digest) 截断） | 支持条件请求；**不泄露原始摘要** |
| `Accept-Ranges` / `Content-Range` | `bytes` | 视频拖动、断点续传 |
| `Content-Disposition` | `inline`（图片/视频）/ `attachment; filename*=…`（文件） | 防内容嗅探攻击；文件名只用于展示 |
| `X-Content-Type-Options` | `nosniff` | 现状已有，保留 |
| `Referrer-Policy` | `no-referrer` | 现状已有，保留（防 Referer 泄露令牌） |
| `Content-Security-Policy` | `default-src 'none'; sandbox`（对可下载的 HTML/SVG 类附件） | 防"媒体 XSS"（Phase 4 若放开 SVG/HTML 附件必须） |

### 11.3 令牌（签名 URL）设计

**【提案】令牌载荷**（服务端签名，客户端不可伪造、不可延长）：

```jsonc
{
  "v": 1,
  "media_id": "…", "variant": "video_720",
  "sub": "user_456",            // ★ 绑定 viewer（修正 A14：现状令牌不含 viewer）
  "aud_scope": "room:!room:server | audience:moment_5 | public",
  "perm": "read|read_original",
  "iat": 1737000000, "exp": 1737000300,     // ★ 服务端强制，短 TTL
  "jti": "…",                                // 可单次使用（single_use 时登记已用）
  "bind": { "ua_hash": "…" } | null          // 可选：弱绑定 UA/IP 段（权衡：移动网络切换会误伤）
}
```

与现状的差异（都是修正审计发现）：

| 现状问题 | 设计修正 |
| --- | --- |
| 读取端点无鉴权（能力 URL = 权限） | 令牌**可选**要求 `Authorization` 头匹配 `sub`（高敏感内容强制）；否则至少绑定 `aud_scope` 并在边缘限速 |
| TTL 由客户端 `expires_in` 决定（可到 7 天） | **服务端强制**：TTL 由 `visibility_hint` + `purpose` 决定（[提案] private 300s / audience 900s / public 24h），客户端参数被忽略 |
| 令牌可被"洗白"为永久引用（无 TTL 解码） | 引用写入时**必须**用**新签发**的引用凭据（一次性的 `reference_token`），不复用下载令牌 |
| 多用途无限次 | `single_use`、`max_uses`、`jti` 登记 |
| 撤销不能立即生效 | 令牌短 TTL + `grant_version`（撤销时递增，令牌携带版本，校验时比对） |

---

## 12. CDN Design

### 12.1 现状与矛盾

- **现状没有 CDN**（审计 §4.5），且业务媒体一律 `private, no-store`，nginx 无 `proxy_cache`。
- 既有的 E2EE 媒体带 `Authorization` 头（`uri_extension.dart:60-61`）⇒ **共享缓存天然失效**
  （缓存键不能包含每个用户的 token，否则命中率为 0）。
- 所以 CDN 设计必须从"**哪些内容能变成可缓存 URL**"出发，而不是"挂一个 CDN"。

### 12.2 【提案】三级缓存策略

```
                ┌──────────────────────────────────────────────────────┐
 Level          │ 缓存键                             │ 命中粒度        │
────────────────┼────────────────────────────────────┼─────────────────┤
 L1 public      │ /media/public/{media_id}/{variant}/{version}        │ 全体用户共享
 (头像/公开封面) │ （无签名；版本号可变；长 TTL + immutable）           │ → CDN 命中率最高
────────────────┼────────────────────────────────────┼─────────────────┤
 L2 audience    │ /media/a/{audience_token}/{media_id}/{variant}      │ 同一受众共享
 (群聊/朋友圈)   │ audience_token = 签名({scope, exp})，**不含 user**  │ → 命中率高（同群同 URL）
────────────────┼────────────────────────────────────┼─────────────────┤
 L3 private     │ 不进入 CDN 缓存；边缘只做 TLS/连接复用/Range 透传    │ 命中率 0（但省不了）
 (E2EE 附件/原图)│ （可用"边缘鉴权 + 回源"或私有缓存，键含 token 片段） │
                └──────────────────────────────────────────────────────┘
```

三点关键论证：

1. **L2 是最大收益点**：群聊/朋友圈里"同一张图被同一批人反复拉取"，若令牌只绑定**受众**
   （房间/动态受众）而**不绑定具体用户**，则同一受众内所有客户端请求同一个 URL，
   CDN 命中率接近 100%。代价：**受众内任何成员泄露 URL，同受众其他人可用**（在受众边界内等价，
   因为房间成员本来就能看这条消息）——这个代价必须写在产品决策里。
2. **L3 不能靠公共 CDN**：E2EE 附件必须带用户凭证。
   【提案】L3 只做"**边缘卸载 TLS + Range 优化 + 连接复用 + 回源收敛**"，
   并可选启用 CDN 厂商的"私有缓存/签名 Cookie"能力（token 在 Cookie 或路径里但缓存键去掉签名部分 ⇒
   需要 CDN 支持 `Cache Key` 自定义，属于部署层选型）。
   **绝不允许**为了缓存而把 L3 变成"无签名可公开读取"。
3. **E2EE 的字节本身可缓存，鉴权不可共享**：密文对 CDN 是"不可读的随机数据"，
   所以放 CDN 不增加内容泄露风险；风险在于"谁能取到"。

### 12.3 【提案】防盗链与滥用防护

| 措施 | 说明 |
| --- | --- |
| 短 TTL 签名 | L1 24h/版本化；L2 900s；L3 300s（服务端强制） |
| 版本化 public 路径 | 头像用 `avatar_version`（现状客户端键已是 `avatar:<userId>:<version>`，客户端审计 §4.2），旧版本立即失效 |
| Referer/Origin 校验 | 仅对 Web 端有意义；移动端以签名+TTL为主 |
| 边缘限速 | 【提案】按 IP + 按 token 的 `limit_req`/`limit_conn`（现状 nginx 完全没有，审计 §4.3） |
| 热点保护 | 同 URL 回源合并（request collapsing）+ 边缘 stale-while-revalidate |
| 计量与告警 | 回源率、带宽、4xx/5xx、异常拉取（同一 token 多 IP） |
| 封禁能力 | 对象/受众级 blocklist（与 quarantine 联动：隔离对象对所有层级立即 404/403） |

### 12.4 与"不要实现 CDN 改造"的关系

用户明确：**CDN 改造属于 Phase 3 后半阶段**。因此本节只给：
① 分层模型与 URL 形态；② 令牌与缓存键的约束；③ 需要 CDN 支持的**能力清单**
（自定义 Cache Key、签名 URL/Cookie、Range 透传、request collapsing、按 token 限速）。
**不选厂商、不改 nginx/CDN 配置、不实现。**

---

## 13. Database Schema

> 用户要求的五张表 + 本设计论证必需的两张辅助表（`media_blobs`、`media_gc_runs`）。
> **不要求实际创建**；本阶段不新增任何 migration。
> 全部为【提案】，且遵循仓库既有规范：expand-migrate-contract、不破坏性迁移、显式索引、append-only 审计。

### 13.1 `media_objects`（逻辑实体）

```sql
-- 【提案】
CREATE TABLE media_objects (
  media_id          TEXT PRIMARY KEY,              -- ULID：不透明、不含内容信息
  owner_id          TEXT NOT NULL,                 -- 上传者（配额/审计口径）
  origin_domain     TEXT NOT NULL,                 -- chat|moments|avatar|file|system
  kind              TEXT NOT NULL,                 -- image|video|audio|file|gif
  canonical_mime    TEXT NOT NULL,
  canonical_size    BIGINT NOT NULL,
  width             INTEGER, height INTEGER, duration_ms BIGINT,
  digest_kind       TEXT NOT NULL,                 -- plaintext_sha256_v1|ciphertext_sha256_v1
  content_digest    TEXT NOT NULL,                 -- 权威摘要（服务端算）
  envelope_mode     TEXT NOT NULL,                 -- none|matrix_v2_envelope|deterministic_v1
  envelope_version  INTEGER NOT NULL DEFAULT 1,
  dedup_eligible    BOOLEAN NOT NULL DEFAULT FALSE,
  status            TEXT NOT NULL,                 -- uploading|ready|quarantined|orphan|collected
  visibility_hint   TEXT NOT NULL,                 -- private|audience|public
  ref_count         INTEGER NOT NULL DEFAULT 0,    -- 缓存列；真相源为 media_references
  created_at        TIMESTAMPTZ NOT NULL,
  ready_at          TIMESTAMPTZ,
  unreferenced_at   TIMESTAMPTZ,
  last_access_at    TIMESTAMPTZ,
  collected_at      TIMESTAMPTZ
);
CREATE UNIQUE INDEX uq_media_objects_digest
  ON media_objects (digest_kind, envelope_mode, envelope_version, content_digest)
  WHERE status <> 'collected' AND dedup_eligible;      -- ★ 只有"可去重"的对象占唯一位
CREATE INDEX ix_media_objects_owner   ON media_objects (owner_id, created_at DESC);
CREATE INDEX ix_media_objects_gc      ON media_objects (status, unreferenced_at)
  WHERE status IN ('orphan','ready');
CREATE INDEX ix_media_objects_access  ON media_objects (last_access_at);
```

设计说明：

- **`dedup_eligible` 参与唯一索引**：非确定性信封（随机 key/IV）**不占**唯一位，因此永远不会被误复用
  （§4.4）。这也让"关闭确定性加密"变成一个纯粹的开关（新对象不再共享），不影响历史行。
- 索引 `WHERE` 子句让"已回收对象"释放摘要位（现状补丁用 `retiring` + `forget` 达到同一效果）。
- `canonical_*` 是**规范元数据**；逐引用元数据（例如每个上传者的文件名）留在 references/业务表
  （与现状补丁一致：canonical 用首个 blob 的元数据）。

### 13.2 `media_blobs`（物理字节）

```sql
-- 【提案】
CREATE TABLE media_blobs (
  blob_id           TEXT PRIMARY KEY,
  media_id          TEXT NOT NULL REFERENCES media_objects(media_id),  -- 归属（可空以支持多对象共享，见下）
  digest_kind       TEXT NOT NULL,
  content_digest    TEXT NOT NULL,
  size              BIGINT NOT NULL,
  mime              TEXT NOT NULL,
  storage_backend   TEXT NOT NULL,   -- matrix_media_store|business_private_dir|s3_v1
  storage_key       TEXT NOT NULL,
  envelope_mode     TEXT NOT NULL,
  envelope_version  INTEGER NOT NULL DEFAULT 1,
  status            TEXT NOT NULL,   -- staged|verified|active|retiring|deleted
  dedup_eligible    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at        TIMESTAMPTZ NOT NULL,
  verified_at       TIMESTAMPTZ,
  retiring_at       TIMESTAMPTZ,
  deleted_at        TIMESTAMPTZ
);
CREATE UNIQUE INDEX uq_media_blobs_digest
  ON media_blobs (digest_kind, envelope_mode, envelope_version, content_digest)
  WHERE dedup_eligible AND status <> 'deleted';
CREATE INDEX ix_media_blobs_media  ON media_blobs (media_id);
CREATE INDEX ix_media_blobs_gc     ON media_blobs (status, retiring_at);
```

> 关于 `media_id` 归属：**更干净的做法**是 `media_variants.blob_id → media_blobs`，
> 让 blob 与 object 完全多对多（同一字节被多个 object 复用）。`media_blobs.media_id`
> 只保留"首次入库归属"用于配额/审计。**取舍**：多对多需要额外的
> `blob_objects(blob_id, media_id)` 关系表或依赖 variants 反查；
> 【提案】采用"variants 反查 + 首次归属"的折中，避免额外表。

### 13.3 `media_variants`（演绎版）

```sql
-- 【提案】
CREATE TABLE media_variants (
  variant_id      TEXT PRIMARY KEY,
  media_id        TEXT NOT NULL REFERENCES media_objects(media_id),
  kind            TEXT NOT NULL,      -- original|image_chat_1280|thumbnail_800|video_720|poster|preview_video|…
  blob_id         TEXT REFERENCES media_blobs(blob_id),
  status          TEXT NOT NULL,      -- pending|processing|ready|failed|skipped
  mime            TEXT, codec TEXT,
  width INTEGER, height INTEGER, duration_ms BIGINT, bitrate_bps INTEGER,
  size            BIGINT,
  generation      INTEGER NOT NULL DEFAULT 1,
  derived_from    TEXT,               -- 族谱：来源 variant kind
  is_primary      BOOLEAN NOT NULL DEFAULT FALSE,
  failure_reason  TEXT,
  created_at      TIMESTAMPTZ NOT NULL,
  ready_at        TIMESTAMPTZ
);
CREATE UNIQUE INDEX uq_media_variants_kind
  ON media_variants (media_id, kind, generation);
CREATE INDEX ix_media_variants_ready ON media_variants (media_id, kind)
  WHERE status = 'ready';
CREATE INDEX ix_media_variants_queue ON media_variants (status, created_at)
  WHERE status IN ('pending','processing');
CREATE INDEX ix_media_variants_blob  ON media_variants (blob_id);
```

### 13.4 `media_references`（业务引用）

```sql
-- 【提案】
CREATE TABLE media_references (
  reference_id   TEXT PRIMARY KEY,
  media_id       TEXT NOT NULL REFERENCES media_objects(media_id),
  variant_kind   TEXT,                     -- NULL = 跟随主档
  business_type  TEXT NOT NULL,            -- chat_message|group_message|moment|moment_comment|moment_cover|avatar|file|announcement|uploader
  business_id    TEXT NOT NULL,
  room_id        TEXT,                     -- 可选，便于按房间清理
  ref_kind       TEXT NOT NULL,            -- observed|declared
  state          TEXT NOT NULL,            -- active|released
  created_at     TIMESTAMPTZ NOT NULL,
  released_at    TIMESTAMPTZ,
  release_reason TEXT
);
-- 幂等：同一业务对象对同一 media 只允许一条活引用
CREATE UNIQUE INDEX uq_media_references_active
  ON media_references (media_id, business_type, business_id)
  WHERE state = 'active';
CREATE INDEX ix_media_references_lookup ON media_references (business_type, business_id);
CREATE INDEX ix_media_references_media  ON media_references (media_id) WHERE state = 'active';
CREATE INDEX ix_media_references_room   ON media_references (room_id, created_at DESC);
```

### 13.5 `media_access_grants`（权限）

```sql
-- 【提案】
CREATE TABLE media_access_grants (
  grant_id       TEXT PRIMARY KEY,
  media_id       TEXT NOT NULL REFERENCES media_objects(media_id),
  variant_scope  JSONB NOT NULL,          -- ["image_chat_1280","thumbnail_800"] 或 ["*"]
  subject_type   TEXT NOT NULL,           -- user|room|audience|public|service
  subject_id     TEXT NOT NULL,
  permission     TEXT NOT NULL,           -- read|read_original|list|delete|admin
  derived_from   JSONB,                   -- {rule, ref}：可实时复核的授权推导
  grant_version  INTEGER NOT NULL DEFAULT 1,   -- 撤销即递增；令牌携带版本
  expires_at     TIMESTAMPTZ NOT NULL,    -- 服务端强制
  single_use     BOOLEAN NOT NULL DEFAULT FALSE,
  issued_by      TEXT NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL,
  revoked_at     TIMESTAMPTZ, revoke_reason TEXT
);
CREATE UNIQUE INDEX uq_media_grants_subject
  ON media_access_grants (media_id, subject_type, subject_id, permission)
  WHERE revoked_at IS NULL;
CREATE INDEX ix_media_grants_expiry ON media_access_grants (expires_at) WHERE revoked_at IS NULL;
CREATE INDEX ix_media_grants_subject_lookup ON media_access_grants (subject_type, subject_id, media_id);
```

### 13.6 `media_upload_sessions`（大文件上传会话）

```sql
-- 【提案】
CREATE TABLE media_upload_sessions (
  upload_id      TEXT PRIMARY KEY,
  owner_id       TEXT NOT NULL,
  origin_domain  TEXT NOT NULL,
  kind           TEXT NOT NULL,
  declared_size  BIGINT NOT NULL,
  declared_mime  TEXT NOT NULL,
  digest_claim   TEXT,                    -- 客户端声明（仅明文域允许；**不用于去重**）
  digest_claim_kind TEXT,
  envelope_mode  TEXT NOT NULL,
  envelope_version INTEGER NOT NULL DEFAULT 1,
  part_size      BIGINT NOT NULL,
  uploaded_parts JSONB NOT NULL DEFAULT '[]',  -- [{n,size,etag,uploaded_at}]
  uploaded_bytes BIGINT NOT NULL DEFAULT 0,
  status         TEXT NOT NULL,           -- created|uploading|verifying|committed|aborted|expired
  media_id       TEXT,                    -- commit 后回填
  idempotency_key TEXT NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL,
  updated_at     TIMESTAMPTZ NOT NULL,
  expires_at     TIMESTAMPTZ NOT NULL
);
CREATE UNIQUE INDEX uq_media_upload_idem ON media_upload_sessions (owner_id, idempotency_key);
CREATE INDEX ix_media_upload_status ON media_upload_sessions (status, expires_at);
CREATE INDEX ix_media_upload_owner  ON media_upload_sessions (owner_id, created_at DESC);
```

### 13.7 `media_gc_runs`（回收审计与可运营性）

```sql
-- 【提案】
CREATE TABLE media_gc_runs (
  run_id        TEXT PRIMARY KEY,
  mode          TEXT NOT NULL,            -- dry_run|enforce
  scope         TEXT NOT NULL,            -- account|domain|global
  scanned       BIGINT NOT NULL DEFAULT 0,
  candidates    BIGINT NOT NULL DEFAULT 0,
  collected     BIGINT NOT NULL DEFAULT 0,
  skipped_pinned BIGINT NOT NULL DEFAULT 0,
  bytes_reclaimed BIGINT NOT NULL DEFAULT 0,
  started_at    TIMESTAMPTZ NOT NULL,
  finished_at   TIMESTAMPTZ,
  error_code    TEXT
);
```

### 13.8 与现状表的对照（迁移映射，不搬数据）

| 现状表 | 映射 | 迁移策略 |
| --- | --- | --- |
| `chatflow_media_blobs` | `media_blobs`（`digest_kind=ciphertext_sha256_v1`, `dedup_eligible=true`） | Phase B：**视图/适配层**先读旧表；Phase C 惰性回填 |
| `chatflow_media_references` | `media_references`（`business_type='uploader'`, `ref_kind='observed'`） | 同上 |
| `chatflow_media_pending` | `media_upload_sessions`（`status='verifying'`）+ `media_blobs.status='staged'` | 新协议内建等价语义；旧表保留 |
| `local_media_repository` | `media_blobs.storage_key` 的解析来源 | 不改 Synapse 表；只读映射 |
| `moment_media_uploads` | `media_upload_sessions`（完成态 → `media_objects`+`media_references`） | Phase B 起双写；Phase C 惰性回填 |
| `avatar_uploads` | 同上（`content_hash` → `content_digest`，`digest_kind=plaintext_sha256_v1`） | 同上 |
| `moments.image_urls` / `image_object_keys` / `cover_object_key` | `media_references`（`moment*`） | Phase C 惰性回填 |
| `users.avatar_object_key` | `media_references`（`avatar`） | 同上 |

---

## 14. Migration Strategy

### 14.1 四阶段（用户给定框架）

```
Phase A：新增 Media Gateway（**不改变旧流程**）
    · 新服务/新模块上线，只提供"影子"能力：读旧表、建内存映射、暴露只读查询
    · 所有写入仍走旧路径（Matrix upload / 业务 begin-put-complete）
    · 验收：新旧读取结果一致；关掉 Gateway 一切如常（可回退 = 删模块）
        │
Phase B：新上传进入 Media Object
    · 新客户端/新版本走统一上传协议；旧客户端继续走旧接口（双入口并存）
    · 双写：对象/变体/引用 与 旧表同时写（旧表为兼容源）
    · 新协议产出的 blob 必须能被旧读取路径解析（对接点：Matrix mxc:// 映射）
    · 验收：新上传的对象可被新旧两条读取路径读到；关开关回退到旧写入
        │
Phase C：旧资源 lazy migrate（**按访问惰性回填，不搬字节、不重加密**）
    · 首次访问旧对象 → 建 media_objects/blobs/variants/references 行（后台批处理兜底）
    · **绝不移动/改名/重加密旧文件**；storage_key 直接指向既有路径
    · 旧 `mxc://` / `media://` 永久可读（映射表 + 旧路径回退）
    · 验收：抽样旧对象回填正确；回填失败不影响读取
        │
Phase D：删除旧入口
    · 旧上传端点下线（保留只读兼容 N 个版本周期）；旧表转历史/只读
    · 验收：旧客户端在支持窗口内仍可读；旧写入比例归零
```

### 14.2 每阶段的可回退性与数据安全

| 阶段 | 回退动作 | 数据影响 | 破坏性 |
| --- | --- | --- | --- |
| A | 停用/删除 Gateway 模块 | 无（只读） | 无 |
| B | 关闭"新路径"开关（回到旧写入）；已写的新对象**保留可读** | 新对象行保留 | 无 |
| C | 停止回填任务；已回填行保留（可重建） | 只增元数据 | 无 |
| D | 重新打开旧入口（代码回滚） | 旧表未删 | 无 |

**硬约束**（AGENTS.md + 用户要求）：

- 禁止破坏性迁移；schema 变更走 expand-migrate-contract，先加列/加表，后切读，最后（可选）清理；
- 字节永不移动（尤其 E2EE：`mxc://` 与事件内容不可变，重新加密/搬移会破坏历史消息）；
- 旧数据永远可读：**任何阶段回退都不得让旧消息里的媒体打不开**；
- 元数据可重建：任何 Phase 3 表被清空，都必须能靠字节 + 业务表 + 补丁表重建。

### 14.3 不变量（跨阶段验收清单）

1. E2EE 附件：服务端永不接收明文摘要/密钥；Megolm 与事件格式不变。
2. `mxc://` 永久可解析；旧 `media://` 永久可解析。
3. 同一密文跨用户仍共享一份字节（现状行为不得退化）。
4. 头像的"版本化 URL + 刷新语义"不变（客户端 `avatar:<userId>:<version>` 缓存键不得失效）。
5. 朋友圈可见性规则不变（授权仍实时复核）。
6. 不新增"必须迁移才能用"的用户可见行为。
7. 每个新开关默认安全（关闭即回到现状），且**关闭不删数据**。

### 14.4 迁移的对账与验收工具（【提案】）

- **一致性对账**：`media_objects/blobs` ↔ 旧表 ↔ 磁盘文件 三方比对（计数 + 抽样摘要），
  输出差异清单（不自动"修复"）。
- **迁移进度看板**：回填对象数/失败数/跳过原因（按域）。
- **暗读（dark read）**：Phase A/B 期间同时用新旧路径读，比对结果与耗时，**以旧路径结果为准**。
- **容量回归**：沿用 `scripts/loadtest` 与 `docs/runbooks/thousand-member-capacity.md` 的场景，
  在每次阶段切换后重跑（现状基线：200 VU PASS / 500 VU 需预热且未验收，见审计 §4.6）。

---

## 15. Security Analysis

> 用户要求的七项：hash 泄露、unauthorized access、reference 越权、URL 泄露、CDN abuse、replay、expired token。
> 每项给出「现状（有证据）→ 设计对策 → 残余风险」。

### 15.1 hash 泄露 / 存在性探测

- **现状**：E2EE 域明面上不泄露（客户端不传明文摘要）；但确定性加密使密文摘要 ≈ 明文指纹，
  服务器与任何能看到索引的人都能做"候选文件确认"；业务域头像已自行计算明文摘要（仅用于会话冲突检查）。
- **设计对策**：
  - 摘要永不入日志/URL/API 回显；`ETag` 用 HMAC 派生（§11.2）；
  - `(digest_kind, envelope_version)` 隔离，禁止跨类比较；
  - **不提供**"按摘要查询是否存在"的客户端接口（§10.3）；去重响应不区分"复用"与"新建"给外部可观测的差异
    （【提案】响应体统一为 `media_id`，不返回 `deduplicated: true/false` 给客户端；
    内部指标可统计，但**这不是安全边界**，只是降低探测效率）；
  - 去重门槛（小文件不去重，§7.6）；
  - 可选 C2（HMAC 索引）保护"数据库泄露"场景（§7.4）。
- **残余风险**：在线确认攻击无法根除（只要有去重）；文件长度/时序仍可观察；
  图片经压缩后字节指纹与原始文件不同，因此"确认攻击"对**处理后的字节**有效，对用户相册原片无效（限缩了面）。

### 15.2 unauthorized access（未授权访问）

- **现状**：三个业务读取端点无鉴权（能力 URL）；Matrix 靠 token + 房间成员资格；
  测试已覆盖"可见性撤销后 404""盗用他人引用 422"（`tests/business_api/moments/test_media_privacy.py:31-45`）。
- **设计对策**：§8.3 的 fail-closed 判定；令牌绑定 `sub`/`aud_scope`（§11.3）；
  高敏感内容强制 `Authorization` 匹配；实时复核（成员资格/可见性）；
  授权缓存 ≤5s + 撤销版本号；管理员/客服访问**必须**走带审计的端点（现状**没有**管理媒体端点，风险 A18 关联）。
- **残余风险**：短 TTL 内已泄露令牌仍可用（窗口 = TTL）；受众级令牌在受众内可横向传递（明确的产品取舍）。

### 15.3 reference 越权（引用越权）

- **现状（真实缺陷）**：把签名 URL 变成永久 `media://` 引用时**不校验 TTL**
  （`services/business-api/app/modules/moments/media_access.py:22,31`），
  一个早已过期的自有权 URL 仍能被写成新动态的永久引用；
  另外"被删除动态的字节仍可被重新挂载"（同一 `owned_key` 逻辑）。
- **设计对策**：
  - 引用写入必须使用**一次性的 `reference_token`**（用途绑定：`purpose=attach_moment`，
    单次、短 TTL、绑定 subject），**不复用下载令牌**；
  - 引用写入时校验：对象存在、owner 相符、状态 `ready`、未被隔离、变体在该对象的授权范围内；
  - 引用与对象状态联动：对象进入 `quarantined` ⇒ 所有引用立即不可读（现状 Synapse 侧已有隔离语义，
    业务侧需对齐）；
  - 引用释放采用"显式释放 + 对账"，禁止"猜引用"。
- **残余风险**：业务域内"同一用户把同一对象挂到多个动态"是**合法**的（需引用计数正确），
  设计必须允许并正确计数（不能把它当越权）。

### 15.4 URL 泄露

- **现状**：能力 URL 无鉴权、可被 Referer/日志/截图/转发泄露；TTL 客户端可控（可到 7 天）；
  `no-referrer` 头已存在（缓解 Referer 泄露）。
- **设计对策**：服务端强制短 TTL；绑定 viewer/受众；`single_use` 高敏感；
  令牌不写日志（审计只记 `jti` 与 subject）；支持撤销（`grant_version`）；
  对"同一令牌多 IP/多 UA 并发"告警。
- **残余风险**：移动端 URL 进系统相册/浏览器历史不可避免；用户主动分享无法阻止（这是产品问题）。

### 15.5 CDN abuse

- **现状**：无 CDN，因此当前 abuse 面集中在源站（无限流、无配额、无计量，审计 A4/A6）。
- **设计对策**：L1/L2 才进缓存且带版本与 TTL；边缘限速与并发限制；request collapsing 防回源放大；
  热点对象预热与 stale-while-revalidate；按受众/对象级封禁；带宽与回源率告警；
  签名 URL 不可长期复用。
- **残余风险**：L2 受众 URL 被大规模外泄 ⇒ 变成"准公开 CDN"（需要短 TTL + 异常检测）。

### 15.6 replay（重放）

- **现状**：下载令牌多用途可重放（TTL 内无限次）；上传侧业务接口已有 `Idempotency-Key`
  （`api/moments.py`、`api/profile.py`、`api/media.py` 之外的部分），上传内容有"同会话不可覆盖"约束
  （`modules/moments/media.py:153-154`，`identity/profile.py:295-299`）。
- **设计对策**：上传 create/complete 强制 `Idempotency-Key`（同 key 同 payload 幂等返回；
  同 key 不同 payload → 409）；分片 PUT 幂等（同 `n` 覆盖需 etag 一致）；
  令牌 `jti` + `single_use`/`max_uses`；跨域写操作沿用"业务幂等 + 审计 + Outbox"（仓库既有规范）。
- **残余风险**：幂等键被滥用做"探测"（用不同内容试同一 key）需审计与限流。

### 15.7 expired token

- **现状（真实缺陷）**：`expires_in` 是请求参数，客户端可把 300 改成 604800
  （`private_storage.py:66,82-89`）；引用写入不校验 TTL（§15.3）；
  读取不复核上传会话过期（`media_access.py:68`）。
- **设计对策**：TTL 服务端唯一决定（令牌内含 `exp`，校验时以**服务端时钟**为准，忽略客户端参数）；
  时钟纪律沿用 `docs/adr/0067-production-clock-discipline.md`；
  引用/读取路径**必须**校验对象与 grant 的有效期；过期一律 404/403 且**不泄露对象是否存在**（统一错误体）。
- **残余风险**：设备时钟与服务器时钟偏差（已由 ADR-0067 处理）；长时播放需要令牌刷新（§11.1 的 tokens 端点）。

### 15.8 其它安全设计点（本设计的补充）

| 主题 | 设计 |
| --- | --- |
| 内容扫描/合规 | 【提案】在 Blob 落盘后、发布前留"可扫描"钩子（`status=quarantined` 与现状 Synapse 语义对齐）；明文域可做哈希黑名单（**注意**：哈希黑名单本身就是一种存在性探测，需要在隐私评审中权衡）；E2EE 域**无法扫描**，这是 E2EE 的既有代价，必须在产品上明示 |
| 恶意文件 | 图片/GIF 的像素预算（现状已有：`modules/moments/media.py:17-18`）；视频转码在**沙箱/限额**内运行；附件强制 `Content-Disposition: attachment` + `nosniff`；禁止 SVG/HTML 直出（除非 CSP `sandbox`） |
| 路径穿越 | 现状已有 containment 校验（`private_storage.py:105-113`）；新 Blob 层必须保留同等校验（storage_key 规范化 + 白名单前缀） |
| MIME 混淆 | 服务端**不信任**客户端 mime：容器探测（magic bytes / ffprobe / Pillow）后写 `canonical_mime`；不匹配则拒绝（现状业务侧已做部分：GIF 伪装 JPEG 被拒，`tests/business_api/moments/test_moment_gif_media.py:143-156`） |
| 配额与滥用 | 每用户/每域字节配额 + 上传速率 + 并发会话数；超限 429/413 并审计 |
| 密钥管理 | 平台不持有附件密钥；平台自身密钥（签名、HMAC 索引）走密钥管理 + 轮换预案（轮换会影响签名 URL 与 HMAC 索引，需要版本化） |
| 审计 | 对象/Grant/上传/删除/GC/管理员访问全部写审计（不含摘要与内容）；现状只有头像 complete/delete 有审计（审计 A17） |

---

## 16. Performance Analysis

> 说明：**除标注"实测"外，本节数字均为设计目标或推算（【估算】），不是测量结论。**
> 唯一实测基线来自 `docs/verification/2026-09-10-media-capacity-runtime.md`（本机隔离环境）。

### 16.1 实测基线（引用，勿当作生产结论）

| 项 | 实测 | 出处 |
| --- | --- | --- |
| 200 VU 同步 | 6/6 轮 PASS（首次同步 p95 0.399–22.967s） | 容量报告 |
| 500 VU 同步 | 首次升档 2 轮 FAIL（>30s），预热后 4 轮 PASS；**不能判定稳定达标** | 容量报告 |
| 服务峰值 CPU | postgres 299.85%、synapse 112.24%、sync worker 116.34%（4 vCPU 测试机） | 容量报告 |
| 生产宿主 | 8 vCPU / ≈7.9 GB RAM / 174 GB 可用；同机还有其他服务 | `docs/verification/2026-09-10-media-framework-production.md:12-13` |
| 媒体记录数 | 549 → 550 条（2026-09-10 发布） | 同上 |

**结论**：当前系统的**已验收**上限是 200 VU 量级；500 VU 未验收；**千人/万人从未验收**。
因此 §16 的目标必须配"分批验收"，不能声称已达 Telegram 级。

### 16.2 目标（用户给定）

| 场景 | 目标 | 设计手段 |
| --- | --- | --- |
| 图片"秒开" | 【目标】首字节 p50 ≤ 200 ms、p95 ≤ 800 ms（4G/家宽）；缩略图 ≤ 100 KB | 缩略图优先（现状已有） + L1/L2 CDN + 长缓存 + 客户端本地缓存（Phase 2） |
| 视频快速播放 | 【目标】首帧 ≤ 1 s（本地已有 poster），可播放 ≤ 2 s（preview_video），拖动 ≤ 500 ms（Range） | poster 先出 + preview_video + Range + 变体选档；E2EE 域依赖客户端预生成产物（§5.4 约束） |
| 大群（1000 人） | 【目标】一条媒体消息在 1000 人群内扇出不产生 1000 次源站回源；峰值带宽由 CDN 承担 | L2 受众级 URL + request collapsing + 客户端并发上限（现状客户端已有全局视频并发 1） |
| 高并发（万人同时访问） | 【目标】源站只承担 ~5% 流量（CDN 命中 ≥95%）；源站 P95 不劣化 | 三级缓存（§12.2）+ 令牌刷新不影响缓存键 + 边缘限速 |

### 16.3 容量模型（【估算】，含假设）

**扇出带宽**：设一条 720p 视频变体 1.2 MB，1000 人群内 600 人打开：

- 无 CDN：`600 × 1.2 MB = 720 MB` 源站出口，且 `600` 次回源；
- L2 受众 URL + 边缘缓存：同一边缘节点只需 **1 次**回源，其余 `599` 次命中边缘 ⇒ 源站出口 ≈ 1.2 MB/边缘节点。

**万人并发（【估算】）**：设 10k 活跃用户，人均图片请求 20 次/会话、平均 60 KB 缩略图：

- 无 CDN：`10k × 20 × 60 KB = 12 GB`/会话窗口，单机千兆网卡（≈125 MB/s）需 ≈96 s 纯传输；
  叠加磁盘随机读与 TLS 开销 ⇒ 不可接受；
- CDN 命中 95%：源站 `5% × 12 GB = 600 MB` ⇒ 可行（前提是**缓存键同受众一致**，§12.2）。

**存储与去重收益（【估算】）**：
- 业务域：同一张图在朋友圈重复发布 3 次、跨用户相同模板图等场景，内容寻址可省 **30–60%**（取决于重复度，
  需上线后度量）；
- E2EE 域：现状已在省（跨用户同密文共享）；Phase 3 的增量来自**变体层复用**（同一缩略图被多对象共享）。
- 头像：消除"业务目录 + Matrix 两份"（现状审计 §2.3）可省 **~50%** 头像存储。

### 16.4 瓶颈与对策

| 瓶颈 | 现状证据 | 对策 |
| --- | --- | --- |
| 媒体写全局锁 | `chatflow_media_dedup.py:32` + README "measure before sharding" | 【提案】按 `digest` 哈希分桶的多把锁（保持"同摘要互斥"语义）；**先在负载环境测量**，不先优化 |
| 单机磁盘 IOPS | 字节与 DB 同盘 | 冷热分层（热缓存/CDN、冷对象存储）；未来对象存储迁移（Phase 3 后半/Phase 4） |
| 大文件传输 | 50 MiB 上限、整文件内存、**客户端无续传**（§10.1） | §10 分片 + 流式 + Range；客户端需按 §10 的续传语义改造（跨阶段） |
| 客户端重试预算 | Matrix 60 s / 业务 API 20 s 总时限，固定 1 s 间隔整请求重试（审计 §1.5） | 分片级幂等 + 只补缺失片，把"重试成本"从 O(文件) 降到 O(缺失片) |
| 客户端并发 | 媒体发送并发 3；视频内存缓存 32 MiB | 服务端下发分片并发上限；服务端不假设客户端能长期高速上传 |
| 转码 CPU | 现状客户端转码（服务端无转码） | 明文域转码需**独立 worker + 队列 + 限额**；E2EE 域不转码（客户端做） |
| 数据库连接 | `cp_min: 5 / cp_max: 30`（`homeserver.yaml`） | 元数据操作必须避免"每请求一次同步写"（last_access 批量去抖，与 Phase 2 同构） |
| GC 与转码争抢 | 现状无 GC | GC/转码限速 + 低优先级 + 可中断 |
| 令牌校验热点 | 现状无 | 无状态签名校验（HMAC）+ 授权缓存 ≤5s |

### 16.5 必须新增的指标（现状几乎没有，审计 A17）

`media_upload_seconds{variant,domain}`、`media_download_bytes{domain,cache_state}`、
`media_dedup_hits_total / media_dedup_misses_total`（**内部指标，不进客户端响应**）、
`media_variant_queue_depth`、`media_transcode_seconds`、`media_gc_collected_total / bytes`、
`media_quota_used_bytes{user}`、`media_auth_denied_total{reason}`、
`media_token_rejected_total{reason}`、`media_origin_requests_total`（CDN 回源）、
`media_error_total{stage}`。

**隐私要求**：指标标签**不得**包含 media_id、摘要、房间/用户明文（用聚合维度或加盐指纹前缀）。

### 16.6 验收方法（分阶段，不预测"已达标"）

1. 容量脚本沿用 `scripts/loadtest`（`compose.isolated.yml` 已有媒体去重开关：
   `CHATFLOW_MEDIA_DEDUP`），先复现现状基线；
2. 每个 Phase 切换后重跑 200 / 500 / 1000 VU，并把"通过"定义为**明确 SLO**（现状脚本没有延迟 SLO，
   容量报告已指出这一点）；
3. 大文件/弱网矩阵：1 GB / 2 GB，抖动丢包、断点续传、后台被杀恢复；
4. CDN 命中率与回源率必须由 CDN 侧指标证明（不能只看客户端耗时）。

---

## 17. Phase 4 Roadmap

> 用户要求：以下**只列未来规划，不编码、不设计细节**。

| # | 能力 | 前置条件 |
| --- | --- | --- |
| 1 | **AI 媒体分析**（内容理解、OCR、场景识别） | Phase 3 对象/变体/权限就绪；隐私与合规评审（E2EE 域只能在**端侧**做） |
| 2 | **智能压缩**（内容自适应码率/质量） | 转码流水线 + 质量度量；E2EE 域只能端侧 |
| 3 | **自动标签** | AI 分析 + 标签权限模型（标签也是敏感元数据） |
| 4 | **图片搜索**（以文搜图/以图搜图） | 向量索引 + 端侧特征（E2EE 域必须端侧提取） |
| 5 | **视频理解**（章节、字幕、摘要） | 转码产物 + ASR；隐私评审 |
| 6 | （Phase 3 后半）全球媒体去重 | 需 §7.6 的隐私评审与 C2/C3 选型 |
| 7 | （Phase 3 后半）对象存储迁移 | 存储抽象就绪 + 双写/校验/回退方案 + 备份恢复演练 |
| 8 | （Phase 3 后半）CDN 改造 | §12.4 的能力清单与厂商能力确认 |
| 9 | （Phase 3 后半）E2EE 域的"先问后传"/分片先传 | 现状被 ADR-0060 明确列为未完成项 |

---

## 附录 A 目标架构总览

### A.1 上传流程（用户要求的图，含 Phase 3 组件）

```
Client
  │ ① 创建上传会话（幂等）           POST /media/v1/uploads
  ▼
Media Gateway
  │ ② 策略：配额/大小/类型/域限制；分配 upload_id + part_size；登记 media_upload_sessions
  │ ③ 接收分片（流式、可并发、可续传）PUT /uploads/{id}/parts/{n}
  │      · 每片：长度校验 + 服务端自算片摘要
  ▼
Object Storage（Blob 层）
  │ ④ 分片落临时区（staged）；complete 时组装为 blob（或对象存储 multipart 原生组装）
  │ ⑤ 服务端自算权威摘要（明文域=明文摘要；E2EE 域=密文摘要）
  ▼
Metadata DB
  │ ⑥ 去重查表（(digest_kind, envelope_version, digest)）→ 命中则复用 blob_id，未命中则落新 blob
  │ ⑦ 写 media_objects(ready) / media_blobs(active) / media_variants(pending…)
  ▼
Reference
  │ ⑧ 业务方写引用（聊天由事件承载；业务域显式 attach）
  │ ⑨ 变体流水线入队（poster → preview_video → 360/720/1080）
  ▼
Client（拿到 media_id / mxc://；后续读取走 §A.2）
```

### A.2 下载流程（用户要求的图）

```
Client
  │ ① 请求（media_id + 期望变体 + prefer 策略），携带自身凭证
  ▼
Authorization（§8.3）
  │ ② owner / 显式 grant / 业务规则（房间成员资格、朋友圈可见性）
  │ ③ fail-closed；写审计（不含摘要）
  ▼
Variant Resolver（§5.3）
  │ ④ 选档：prefer=auto → 按网络/屏幕/已缓存档位选；未就绪 → 回退 poster / 202+retry
  │ ⑤ 令牌签发（绑定 sub/aud_scope/exp/jti，服务端强制 TTL）
  ▼
CDN（§12.2 三级）
  │ ⑥ L1/L2：命中边缘缓存直接返回；未命中回源并缓存
  │ ⑦ L3：不缓存，只做 TLS/Range/连接复用/回源收敛
  ▼
Client Cache（Phase 2 已交付）
  │ ⑧ 本地对象库 + 索引 + 配额 LRU（384 MiB/账号软、1 GiB 设备硬）
  │ ⑨ 播放：poster → preview_video → 目标档位（Range）
```

### A.3 组件职责边界（避免"平台变成上帝对象"）

| 组件 | 负责 | **不**负责 |
| --- | --- | --- |
| Media Gateway | 会话、校验、去重、对象/变体/引用、授权、令牌、配额 | 不持有 E2EE 密钥；不做矩阵房间状态判定（委托 Matrix）；不做朋友圈可见性判定（委托 Moments） |
| Blob Store | 字节读写、存储后端抽象、临时区与组装 | 不理解业务语义 |
| Variant Pipeline | 转码/缩略图/poster（仅明文域） | **不处理 E2EE 内容** |
| Metadata DB | 对象/变体/引用/权限/会话/GC 运行记录 | 不存内容、不存密钥 |
| Edge/CDN | 缓存与分发 | 不理解权限（只认签名 URL/Cookie） |
| Matrix（现有） | 房间/事件/成员资格/E2EE 传输 | 不是媒体权限的唯一来源（由 Gateway 统一） |
| Moments/Avatar 业务 | 业务规则与可见性 | 不直接碰字节存储（经 Gateway） |

---

## 附录 B 术语表

| 术语 | 含义 |
| --- | --- |
| **Blob** | 物理字节单元（`storage_key` + 摘要 + 信封）。去重与回收的作用对象 |
| **MediaObject** | 逻辑媒体实体；权限与业务引用的作用对象 |
| **Variant** | 演绎版（分辨率/编码/封面/短片）；指向 blob |
| **Reference** | 业务对象（消息/动态/头像）对媒体的引用；计数与回收的依据 |
| **Grant** | 权限授予（subject + permission + expires_at + 可实时复核的推导来源） |
| **Capability URL** | 携带签名的 URL（"持有即可读"）；本设计通过绑定 subject/受众/TTL/次数收紧 |
| **`digest_kind`** | 摘要语义域（明文 vs 密文）；决定可比较性与去重资格 |
| **Envelope** | 加密信封元数据（算法/IV/密文摘要）；平台不持有密钥 |
| **Observed / Declared reference** | 服务端可观测引用 / 客户端声明引用（§6.3） |
| **`dedup_eligible`** | 该对象是否允许跨用户复用（确定性信封 + 门槛满足时才为真） |
| **L1/L2/L3** | 缓存分级：public 版本化 / audience 受众级 / private 不缓存（§12.2） |

---

## 附录 C 开放问题（需产品/隐私/运维决策）

| # | 问题 | 为什么必须由人决策 | 影响章节 |
| --- | --- | --- | --- |
| Q1 | E2EE 去重是否引入 HMAC 索引（C2）或受信盲去重（C3）？ | 涉及隐私强度 vs 复杂度/成本的取舍，且现状已接受"确定性加密的可链接性"（ADR-0060） | §7 |
| Q2 | 去重门槛（多大/多热才允许跨用户去重）？ | 直接决定确认攻击面与存储收益 | §7.6 |
| Q3 | 受众级令牌（L2）是否可接受"受众内 URL 可横向传递"？ | 是产品安全取舍（换取 CDN 命中率） | §12.2 |
| Q4 | `read_original` 是否默认只给 owner？ | 影响体验（转发/保存原图）与隐私 | §8.1 |
| Q5 | E2EE 视频的 preview/多档位由发送端生成吗？ | 端侧算力/流量/耗电 vs 体验；服务端在 E2EE 下**不可能**代劳 | §5.4 |
| Q6 | 保留期数值（E2EE floor 30 天、last_access 延长上限 180 天）？ | 法务/合规/成本 | §9.3 |
| Q7 | 明文域（Moments/Avatar）是否要改为端到端加密？ | 会改变可见性/审核/搜索能力，属产品级变更（本阶段禁止改 E2EE） | §15.8 |
| Q8 | 服务端单文件上限与配额数值？ | 需与磁盘预算（174 GB 可用）和成本模型对齐 | §10.3、§15.8 |
| Q9 | 是否允许内容哈希黑名单扫描？ | 黑名单本身即存在性探测，需隐私评审 | §15.8 |
| Q10 | 千万级/多区域的存储与 CDN 选型？ | 属 Phase 3 后半（用户明确不在本阶段） | §12.4、§17 |

---

## 结语（本阶段的交付边界）

- 本文档是 **Architecture Design Only**：所有 schema、端点、状态机、阈值、容量数字均为**提案**；
  **没有实现**，也**没有**修改 Matrix Server、Matrix 协议、E2EE、媒体上传接口、朋友圈 API、
  数据库 schema 或客户端缓存代码。
- 现状部分（§1、§2 与全部证据行号）来自本次只读审计：
  [media-engine-phase3-server-audit.md](media-engine-phase3-server-audit.md)。
- 与既有决策的关系：**不推翻** ADR-0060（确定性加密 + 密文摘要去重 + 逐用户引用），
  而是把它形式化为 `digest_kind=ciphertext_sha256_v1` 并扩展成跨域对象平台；
  **不改变** Phase 1/2 已交付的客户端行为与本地缓存语义。
- 下一步若获批准：按 §14 的 Phase A 起，以"可回退、可对账、不搬字节"的方式逐步落地，
  并在每个阶段重新跑容量与一致性验收。
