# ChatFlow Media Engine Phase 3.1 — Architecture Freeze

> ## 本阶段：**Freeze Only —— 只冻结，不编码**
>
> 本文档**没有**实现任何东西：未实现 Media Gateway、Media Object Server、Upload Engine、CDN、远端去重；
> 未修改 Matrix Server、Matrix 协议、E2EE、Megolm/Olm、媒体上传接口、Moments API、Avatar API、
> 数据库 schema、客户端缓存代码或 Flutter 业务代码。**本阶段唯一产物就是本文档。**
>
> 本文档的定位：**后续 Phase 4 Implementation 的架构依据（architecture baseline）**。
> 凡标注 **FROZEN** 的条目，Phase 4 必须遵守；如需变更，必须新开一个 ADR 覆盖本文档，
> 不允许在实现中"顺手改语义"。凡标注 **DEFERRED** 的条目，Phase 4 **不得**实现。

- **日期**：2026-09-17（Asia/Hong_Kong）
- **仓库**：`SuperJJ2333/StarChat`（分支 `main`，基线 `81d9e612`，Phase 3 文档已推送）
- **上游输入**：
  [Phase 3 服务端审计](media-engine-phase3-server-audit.md)（现状与 `path:line` 证据）、
  [Phase 3 服务端设计](media-engine-phase3-server-design.md)（候选方案与论证）、
  [Phase 0 设计](media-engine-v1.md)、
  [Phase 2 本地索引](media-engine-phase2-local-index.md)、
  [ADR-0060 内容寻址媒体去重](../adr/0060-content-addressed-media-dedup.md)、
  [客户端媒体审计](../verification/2026-09-17-media-architecture-audit.md)
- **冻结编号约定**：`ADR-001`–`ADR-006`（架构级冻结，Phase 4 必须遵守）与 `D-01..D-15`（用户清单中的 15 个决策，
  映射到 ADR）。两者都在 §4 与 §10 的决策索引中可查。
  其中 **ADR-001 Isolation / ADR-002 Digest / ADR-003 Authorization / ADR-004 Matrix Compatibility /
  ADR-005 Upload Boundary** 是任务书 §22 明确要求的五条记录；
  **ADR-006 Deletion & Lifecycle** 是为承载 D-13（删除策略）与 D-14（`SCANNING` 状态）而增设，
  与上述五条同级、同样具有冻结效力。

---

## 1. Scope

### 1.1 本阶段做什么

| 项目 | 内容 |
| --- | --- |
| 冻结架构边界 | 媒体平台的隔离边界、身份/摘要边界、权限边界、兼容边界、上传边界 |
| 冻结模型 | `MediaObject` / `Blob` / `Variant` / `MediaReference` / 授权与令牌 / 生命周期状态 |
| 冻结策略 | TTL、去重适用范围、删除与 GC、迁移路线、性能目标 |
| 明确不冻结 | 一切需要实测、产品取舍、隐私评审或运维选型的项（§8） |
| 明确 Phase 4 边界 | 可实现范围与禁止范围（§9、§10） |

### 1.2 本阶段明确不做（用户约束）

- **不编码**：不实现 Media Gateway / Media Object Server / Upload Engine / CDN / 远端去重。
- **不修改**：Matrix Server、Matrix 协议、E2EE、Megolm/Olm、媒体上传接口、Moments API、Avatar API、
  数据库 schema、客户端缓存代码、Flutter 业务代码。
- **不部署、不构建、不真机**。
- 本阶段结束时，代码与配置与 Phase 3 结束时**逐字节相同**。

### 1.3 验收标准（用户给定 → 本文档落点）

| 验收标准 | 落点 |
| --- | --- |
| 不编码 / 不修改业务代码 | §1.2、§10 的 "Phase 4 禁止范围" |
| 明确媒体隔离策略 | **ADR-001**（§4.1） |
| 明确 digest 模型 | **ADR-002**（§4.2） |
| 明确权限模型 | **ADR-003**（§4.3） |
| 明确 Matrix 兼容方式 | **ADR-004**（§4.4） |
| 明确 Upload Engine 边界 | **ADR-005**（§4.5） |
| 明确 Variant 生命周期 | ADR-002 §4.2.4 + §4.4 变体状态机 + ADR-006（删除与生命周期） |
| 明确删除策略 | **ADR-006**（§4.6） |
| 明确迁移路线 | §7（Phase A–E） |

---

## 2. Current State

> 本节只复述**已被审计确认的事实**（全部证据见 [服务端审计](media-engine-phase3-server-audit.md)）。
> 冻结决策的每一条都以这些事实为前提。

### 2.1 四个域的真实状态

| 域 | 服务器可见内容 | 存储 | 内容寻址/去重 | 引用 | 权限 | 回收 |
| --- | --- | --- | --- | --- | --- | --- |
| Chat / File（E2EE） | **仅密文** | Matrix `media_store`（bind mount） | **有**：密文摘要 → 共享 `media_id`（已上线） | 有，但语义是"上传者 (media_id,user_id)" | access token + 房间成员资格；**无签名 URL/无过期** | 宽限期 + 引用归零；**无自动 GC 调度** |
| Moments | 明文 | 业务私有目录（bind mount） | **无**（随机 UUID key） | **无** | 读取端点**无鉴权**（能力 URL）+ 实时可见性复核（能力 TTL 固定 300s） | **无任何 GC**；动态删除不删字节 |
| Moments 封面 | 明文 | 同上 | **无** | **无** | 300s 签名（preferences 里 7 天） | 替换封面**不删旧对象** |
| 压缩演绎版 | 明文 | 同上 | **无** | **无（无 DB 行）** | 无鉴权令牌 URL | **无任何记录，无从枚举** |
| Avatar | 明文 | 同上（+ worker 复制一份到 Matrix） | **无**（仅会话内 `content_hash` 冲突检查） | **无** | 无鉴权令牌，**令牌不含 viewer**；TTL 由客户端 `expires_in` 决定（可到 7 天） | 替换/取消/删除时立即物理删除 |

### 2.2 与冻结直接相关的 8 条事实

1. **明文摘要从不进入 E2EE 链路**：`chatflow_media` 与事件内容一起被 Megolm 加密，上传请求只带密文
   （ADR-0060 §4；客户端审计确认）。这是已交付的安全边界，本冻结**继承并强化**。
2. **确定性加密使"密文摘要去重 ≡ 内容去重"**：相同明文 → 相同 key/IV → 相同密文
   （`docs/adr/0060-content-addressed-media-dedup.md:11`）。服务端因此能在不接触明文的前提下跨用户共享一份密文。
3. **现有服务端骨架可复用**：摘要索引 + 逐用户引用 + 宽限期 + 隔离墓碑 + 崩溃补偿
   （`third_party/synapse/chatflow_media_dedup.py`）。Phase 4 是**抽象与扩展**，不是替换。
4. **业务侧零治理**：无内容寻址、无引用计数、无 GC、无配额、无计量、无指标；三个读取端点无鉴权。
5. **能力 URL 语义被滥用**：TTL 客户端可控（可到 7 天）；过期 URL 可被"洗白"成永久 `media://` 引用；
   读取不复核上传会话过期。
6. **状态机有死状态**：`SCANNING` 存在但**没有生产者**，且 `put_content` 不校验过期 ⇒ 上传可永久滞留。
7. **客户端没有可续传上传**：失败即整请求重试（Matrix 60s / 业务 API 20s 总时限）；Synapse 上传上限 **50 MiB**
   ⇒ 1GB+ 视频当前不可能上传。
8. **无 CDN、全 `no-store`、无边缘限流**；媒体字节与数据库**同机同盘**，仓库内无备份脚本。

### 2.3 现状的"架构债"清单（冻结要回答的问题）

| # | 债 | 冻结落点 |
| --- | --- | --- |
| T1 | 存储隔离与读取授权被混为一谈（"谁能读"决定了"东西放哪"） | ADR-001 明确二者分离 |
| T2 | 摘要语义未区分（明文/密文混在一个概念里讨论） | ADR-002 |
| T3 | 权限靠"持有 URL 即有权" | ADR-003 |
| T4 | 每个域各有一套 TTL 规则，且客户端可改 | ADR-003 §4.3.4 |
| T5 | 旧 Matrix 媒体无法被平台统一治理 | ADR-004 |
| T6 | 大文件被"上传接口"绑死（改上传接口 = 改协议） | ADR-005 |
| T7 | 删除语义三套（逻辑删引用 / 立即物理删 / 从不删） | ADR-006 |
| T8 | 状态机存在死状态 | ADR-006 §4.6.5 |

---

## 3. Architecture Goals

### 3.1 目标形态（FROZEN）

```
                        Media Platform
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
      Chat                 Moments               Avatar
   （E2EE 附件）          （明文图片）          （明文图片，延后接入）
        │
   File / Group
        │
   统一：Media Object · Media Variant · Media Reference · Authorization
        Lifecycle · Storage · Metrics
```

**统一的是"治理面"，不是"字节面"**（这是本次冻结最重要的架构判断）：

| 统一 | 不统一 |
| --- | --- |
| 对象/变体/引用的**元数据模型** | 各域的**隔离域与字节归属**（明文域按用户隔离，密文域按密文摘要共享） |
| 授权判定入口与令牌格式 | 各域的**业务授权来源**（房间成员资格 / 动态可见性 / 公开版本） |
| 生命周期与 GC 编排 | 各域的**保留期与可见性策略参数** |
| 指标、审计、配额口径 | 各域的**编码/压缩参数**（不归一化，避免改变发送字节） |
| 存储抽象接口（`storage_key` 由后端解析） | 各域的**存储后端实例**（Phase 4 仍是两个 bind mount） |

### 3.2 架构原则（FROZEN，Phase 4 必须遵守）

| # | 原则 |
| --- | --- |
| P1 | **E2EE 边界不可谈判**：平台永不接收、永不存储、永不比较 E2EE 域的明文摘要；永不持有附件密钥 |
| P2 | **只信服务端自算的摘要**：客户端声明的摘要只作校验/续传记账，永不作为身份、去重键或授权依据 |
| P3 | **元数据可重建，字节是唯一真相**：任何平台表被清空都必须能从字节 + 业务表 + 既有补丁表重建 |
| P4 | **删除先解引用，回收可延迟**：绝不"删消息 = 删文件" |
| P5 | **fail-closed**：授权链路上任何依赖不可用（Matrix/Moments 判定失败）一律拒绝，绝不降级为允许 |
| P6 | **隔离与授权分离**：对象归属决定"存哪、谁能共享字节"；Grant 决定"谁能读"，两者不得互相推导 |
| P7 | **默认安全开关**：每个新能力必须可关闭，且关闭回到现状行为、不丢数据、不破坏可读性 |
| P8 | **不可猜测的不透明 ID**：`media_id`/`blob_id`/`variant_id` 不得由内容摘要派生 |
| P9 | **旧数据永远可读**：`mxc://` 与 `media://` 永久可解析；不重加密、不搬字节、不改事件 |
| P10 | **先测量再优化**：媒体写路径的全局串行锁等瓶颈必须在负载环境测量后才允许分片 |

---

## 4. Decision Records

> 用户清单中的 15 个决策（D-01…D-15）全部在此冻结或显式延后；索引见 §10.2。
>
> 记录清单（任务书 §22 要求的五条 + 一条承载删除/状态机的补充记录）：
>
> | ADR | 主题 | 承载的决策 |
> | --- | --- | --- |
> | ADR-001 | **Isolation** | D-01、D-03（隔离部分） |
> | ADR-002 | **Digest** | D-02、D-03（摘要部分）、D-04（字节层关系） |
> | ADR-003 | **Authorization** | D-06、D-07 |
> | ADR-004 | **Matrix Compatibility** | D-08、D-09、D-10、D-12 |
> | ADR-005 | **Upload Boundary** | D-11、D-15 |
> | ADR-006 | **Deletion & Lifecycle**（补充，同级冻结） | D-13、D-14、D-05、D-04（生命周期层） |

### 4.1 ADR-001 — 媒体隔离策略（对应 D-01、D-03 的隔离部分）

**状态：FROZEN。**

#### 4.1.1 三个选项的分析

| 维度 | Option A 用户空间隔离 | Option B 租户级共享 + AccessGrant | Option C 全球去重 |
| --- | --- | --- | --- |
| 存储形态 | 每个用户独立对象空间；跨用户零共享 | 一个共享对象空间（租户/平台级），靠 Grant 控制读取 | 单一全球对象空间，任何用户相同内容共用一份 |
| 存储影响 | 最差：相同内容 N 个用户 = N 份 | 中：同一隔离域内一份 | 最好：全局一份（理论最优） |
| 安全影响 | 最好：跨用户不存在共享对象，没有"存在性预言机"的跨用户维度；删除/隔离天然局部 | 中：共享对象使"他人是否有此内容"可被推断（存在性/确认攻击）；删除/隔离需引用计数；一次误删影响多个引用者 | 最差：上述问题全部放大到全网，并引入**跨租户合法性与滥用耦合**（一人被隔离 → 全员内容受影响；一次法律删除波及无关用户；无法对单用户做"彻底清除"承诺） |
| E2EE 影响 | 无冲突，但**与已上线的密文去重相冲突**（见下） | 与现状一致（现状就是密文域共享） | 需要把密文域与明文域混在一个空间 → 破坏"摘要种类隔离" |
| 实现复杂度 | 低（现状业务侧就是这样） | 中（Grant + 引用计数 + 乐观并发） | 高（跨租户治理、合规、密钥、审计、误删恢复） |
| 与现状差距 | 业务侧已经是 A；Matrix 侧是"密文域共享" | 需要新建对象空间 | 需要重建整个存储层 |

#### 4.1.2 关键判断：隔离（存储）≠ 授权（读取）

- **读取授权**必然是 Option B 形态（"上传者的对象被群成员读取"），否则群聊/朋友圈无法工作。
- **存储隔离**问的是另一件事：**同一个物理字节是否允许被不同用户的引用共享**。
- 这两件事在现状里被混在一起（"因为 B 能读 A 的图，所以图可以存在共享空间"），是架构债 T1 的根源。

#### 4.1.3 第一阶段正式方案（FROZEN）

> **隔离域（Isolation Domain）模型**：对象空间按"隔离域"划分，跨域永不共享字节。

| 隔离域 | 覆盖 | 字节共享范围 | 依据 |
| --- | --- | --- | --- |
| **`user/<owner_id>`**（明文域） | Moments 图片/封面/评论图、Avatar、压缩演绎版、未来明文附件 | **仅该用户自己的对象之间**（同一用户跨业务复用同字节是安全的） | 服务器持有明文；跨用户共享明文对象会引入存在性预言机 + 滥用/法务耦合，收益不值得 |
| **`e2ee/ciphertext-v1`**（密文域） | Chat / 群聊 / 文件 / 公告的 E2EE 附件 | **跨用户共享同一密文摘要**（现状行为，保留） | 密文摘要去重已在生产，且不向服务器泄露明文；与 ADR-0060 的已接受取舍一致 |
| **`system/public/<version>`** | 平台级公开素材（如默认封面、内置表情） | 全局共享 | 不含用户数据 |

**明确拒绝 Option C（全球去重）作为第一阶段方案**，理由：它把"存储节省"建立在"跨租户存在性/确认攻击面 + 一次删除波及多人 + 无法对单用户承诺彻底清除"之上。
**"不要为了节省存储直接选择高风险方案"** —— 本冻结遵守该要求：明文域选择 Option A（存储最贵、风险最低），
密文域保留已上线的受限共享（不新增风险面），全球去重推迟到有隐私评审支撑的阶段（§8 DEFERRED-1）。

#### 4.1.4 跨域行为的边界（FROZEN）

1. **明文域与密文域永不共享字节**，即使字节相同（因为一个是明文、一个是密文，`digest_kind` 不同，见 ADR-002）。
2. **明文域永不进入跨用户索引**：`(digest_kind='plaintext', digest)` 的唯一约束限定在 `owner_scope` 内。
3. **密文域的对象永不因为"某用户删除了引用"而影响其他用户的引用**（现状补丁已如此：按 `(media_id,user_id)` 隔离）。
4. **E2EE 域不参与"用户空间隔离"**：它不是"某用户的对象"，而是"某密文的对象"，其共享性由确定性加密决定；
   因此**不得**把 E2EE 域的对象迁入 `user/<owner_id>` 空间（那会让同一密文产生多份副本，破坏现状能力）。
5. **删除/隔离的传播范围**：隔离（quarantine）作用于对象，进而使所有域的引用不可读（防止"换个用户重传被封禁内容"，
   现状已有摘要墓碑语义）；但不做跨隔离域的级联删除。

#### 4.1.5 存储影响（接受成本）

| 场景 | Option A 明文域 | 备注 |
| --- | --- | --- |
| 同一用户重复发布同一张图 | 1 份（域内去重） | 域内复用是免费的 |
| 两个用户上传同一张图 | 2 份 | **本冻结接受该成本**（换隐私与治理简单性） |
| 头像 | 每用户 1 份（业务目录）+ 现状还会复制一份到 Matrix | Phase 4 可优化"复制到 Matrix"这一份（DEFERRED-4），但不去重跨用户头像 |

---

### 4.2 ADR-002 — Digest / Dedup 模型（对应 D-02、D-03、D-04 的字节层）

**状态：FROZEN。**

#### 4.2.1 三种摘要种类（FROZEN 命名）

> **禁止 `plaintext hash == cipher hash`**：二者语义不同、可比较性不同、泄露后果不同。
> 平台内一切摘要都以 `(digest_kind, digest_version, value)` 三元组为身份。

| `digest_kind` | 定义 | 谁计算 | 谁可信 | 谁可访问 | 用途 |
| --- | --- | --- | --- | --- | --- |
| **`plaintext_digest`** | 明文字节的 SHA-256 | **仅服务端**，且仅在服务器合法持有明文的域（Moments/Avatar/渲染/系统素材） | 服务端自算 ⇒ **权威可信**；客户端若提交同名字段，视为**非权威声明**，只用于幂等/提前报错 | 平台内部（存储/索引/GC/计费）；**不出现在任何 API 响应、URL、日志、推送**；ETag 用 HMAC 派生值代替 | 明文域内容寻址（**限本用户隔离域内**）、去重、完整性校验、幂等 |
| **`ciphertext_digest`** | 收到的 E2EE 附件字节的 SHA-256（确定性信封下的密文摘要） | **仅服务端**（对收到的字节流式计算） | 服务端自算 ⇒ 权威可信（长度校验防截断） | 同左；**按"敏感指纹"对待**（因确定性加密下它可由明文推算） | **唯一允许的跨用户去重键**（仅密文域，且 `dedup_eligible=true`） |
| **`transport_digest`** | 传输/分片级摘要（每分片 SHA-256，或对象存储分片的 tree/CRC 校验值） | **客户端计算**，服务端复算 | **不可信**（仅用于发现传输错误）；服务端复算结果才是记账依据 | 仅在传输会话与对账记录中；**永不作为身份、永不入库为对象摘要、永不参与去重** | 分片校验、断点续传对账、幂等键派生、弱网快速失败 |

#### 4.2.2 强制规则（FROZEN）

1. **种类隔离**：三种摘要**永不互相比较**；唯一/查询索引按 `digest_kind` 分区。
2. **明文摘要绝不出现在 E2EE 域**：任何"客户端把明文摘要交给服务器用于 E2EE 去重"的实现一律拒绝（ADR-0060 的否决项，本冻结继承）。
3. **客户端摘要永不作权威**：`transport_digest` 与一切客户端声明只做校验；服务端必须自行计算权威摘要。
4. **摘要不进日志/URL/API 回显**；对外可比较值一律用服务端 HMAC 派生（§5.1）。
5. **`media_id`/`blob_id` 不是摘要**（不透明 ID，防"知道 ID 即知道内容"）。
6. **摘要种类与算法版本一同入身份**：`(digest_kind, digest_version, envelope_version)`；
   算法升级 = 新家族，**允许并存，不追删旧对象**（避免"升级即失去全部历史复用"）。

#### 4.2.3 去重适用范围（FROZEN：分层允许）

| 层 | 是否允许去重 | 前提 |
| --- | --- | --- |
| 同一用户、明文域内 | ✅ 允许 | `digest_kind=plaintext_digest`；唯一约束限定 `owner_scope` |
| 跨用户、明文域 | ❌ **禁止**（第一阶段） | 见 ADR-001；未来需隐私评审（DEFERRED-1） |
| 跨用户、密文域 | ✅ **允许（保留现状）** | `digest_kind=ciphertext_digest` 且 `envelope=deterministic_v1` 且 `dedup_eligible=true` 且满足门槛策略 |
| 随机信封（如 Emoji 保险库路径） | ❌ 禁止 | `dedup_eligible=false`（现实例：`MatrixFile.encrypt()` 路径） |
| 跨域（明文 ↔ 密文） | ❌ 禁止 | 种类隔离 |
| 客户端侧"查询是否已存在"接口 | ❌ **不提供** | 会把存在性探测变成廉价 API；现状也没有该接口 |

#### 4.2.4 去重门槛（FROZEN 为策略，数值 DEFERRED）

- 去重**不是无限免费**：必须支持"门槛策略"（最小尺寸 + 可选热度门槛），用于对抗针对小文件的确认攻击。
- **策略冻结**：门槛由服务端配置决定（`MediaDedupPolicy`），**不由客户端指定**；默认必须保守（小文件默认不跨用户去重）。
- **数值未冻结**（DEFERRED-2）：需上线后按实测命中率与隐私评审定值。

#### 4.2.6 E2EE 去重边界（D-03 的冻结结论，附三条技术分析）

**服务器看不到明文媒体**的前提下，三种候选手段的分析（详细论证见 [Phase 3 设计 §7](media-engine-phase3-server-design.md)）：

| 手段 | 分析 | 冻结处置 |
| --- | --- | --- |
| **明文 hash**（客户端算 `SHA256(original)` 交给服务器查重） | **风险**：① 可直接离线字典攻击的指纹入库；② 服务器/入侵者/传票可做"某文件是否存在"的确认；③ 形成"谁上传过这个文件"的关联图；④ 与 E2EE 的"服务器不知道内容"直接冲突（ADR-0060 已否决） | **禁止**（任何域；明文域也不需要——服务器本来就能自算） |
| **密文 hash**（服务端对收到的密文算摘要） | **前提**：随机加密下 `same file ≠ same ciphertext`（nonce/key 随机 ⇒ 去重完全失效）。**现状**：加密是确定性的（key/IV 由明文摘要经固定域 HKDF 派生）⇒ 相同明文必然产生相同密文 ⇒ 密文摘要去重**有效**，且服务器无需接触明文。**残余风险**：确定性加密下密文摘要 = 明文指纹的可计算函数，故仍按"敏感指纹"对待（§5.1 S1） | **允许，且仅限**：`digest_kind=ciphertext_digest` + `envelope=deterministic_v1` + `dedup_eligible=true` + 满足去重门槛 |
| **Convergent encryption / 盲去重 / 加盐索引** | **风险与代价**：① 收敛加密的确认攻击面与②相同（本系统事实上已在跑其 HKDF 变体）；③ 加盐/HMAC 索引需要新增关键密钥资产与轮换策略，且只防"数据库泄露"、不防在线探测；④ 受信盲去重要新增独立服务/协议/故障域与审计面 | **不在第一阶段引入**（DEFERRED-10），仅作为未来增强候选 |

**第一阶段去重边界（FROZEN，逐条明确回答）**：

1. **不做全球 dedup**（拒绝 Option C；理由见 ADR-001 §4.1.3）。
2. **明文域只做"用户空间 dedup"**：去重范围限定在**同一 owner 的隔离域内**，跨用户零共享。
3. **密文域只做"密文对象复用"**：沿用已上线的密文摘要复用（跨用户共享同一密文对象），
   但必须满足"确定性信封 + `dedup_eligible` + 门槛策略"，并且**永不与明文摘要比较**。
4. **不提供**任何客户端可调用的"按摘要查询是否存在"的接口。
5. 去重**永远可关闭**（`MediaDedupPolicy`），关闭后回到"每次上传独立对象"，且**不删除既有映射**。

#### 4.2.7 Object / Blob / Variant 冻结模型（D-04）

**三层关系（FROZEN）**：

```
MediaObject  1 ──── n  Variant  n ──── 1  Blob
（逻辑媒体：身份、归属、权限锚点）  （演绎版：编码/分辨率/状态）  （物理字节：摘要、大小、存储键、信封）
```

- **引用与权限只挂 `MediaObject`**；**摘要与隔离域只挂 `Blob`**；**编码元数据与就绪状态挂 `Variant`**。
- `Blob` 与 `MediaObject` 是**多对多**（同一字节可被多个对象的多个变体复用，限同一隔离域内）。
- 关系变更（新增变体、新增引用）**永不复制字节**；只有"新字节"才产生新 `Blob`。

**冻结的最小字段集**（字段名 FROZEN；实现可增列，不得改变语义）：

| 实体 | 冻结字段（最小集） | 说明 |
| --- | --- | --- |
| **MediaObject** | `media_id`、`owner_scope`、`created_at`、`metadata` | `media_id` = 服务端生成的不透明 ID（非摘要）；`owner_scope` = 隔离域标识（`user/<owner_id>` 或 `e2ee/ciphertext-v1` 或 `system/public/<version>`）；`metadata` = `{kind, canonical_mime, size, width, height, duration_ms, visibility_hint, status, ref_count}` |
| **Blob** | `blob_id`、`digest`、`size`、`storage_key` | `digest` = `(digest_kind, digest_version, value)` 三元组（§4.2.1）；`storage_key` = 后端内部键（不对客户端暴露）；另有 `envelope{mode,version}`、`dedup_eligible`、`status` |
| **Variant** | `variant_id`、`media_id`、`kind`、`blob_id`、`status`、`generation`、`derived_from` | `kind` 取消（FROZEN）：图片 `original / thumbnail / preview / compressed`；视频 `poster / preview / 720p（及 360p/1080p）/ original`（与任务书示例一致，可扩展但不得复用同名字段表达不同语义） |
| **MediaReference** | 见 §4.6.1 | — |

**Variant 冻结规则**：

1. `ready` 之前不可读；`failed` / `skipped` 必须显式（客户端据此降级，不得无限重试）。
2. 新编码参数 = 新 `generation`，**不覆盖**旧 variant；读取默认取最新 ready。
3. 不同字节 = 不同 `Blob`；**不做"视觉相似归并"**（q80 与 q70 必须是两个对象）。
4. 一个逻辑视频的 `poster / preview / 720p / original` **同属一个 `MediaObject`**（族谱用 `derived_from` 表达）。
5. E2EE 域的 variant 由**发送端**产出（ADR-004 §4.4.5），平台只登记不生成。

**Variant 字节层规则（补充，FROZEN）**：

- 变体**不拥有独立摘要种类**：变体的字节同样按所选域规则计算 `plaintext_digest` 或 `ciphertext_digest`。
- **同一变体字节可被多个 `MediaObject` 的 `Variant` 共享**（同一隔离域内），因此"变体级复用"是允许的，
  且是 Phase 4 的主要收益来源之一（例：同一缩略图被多个对象引用）。
- **不同压缩参数的变体是不同字节 ⇒ 不同 blob**（不合并、不"视觉相似归并"）。
  `q80` 与 `q70` 必须是两个对象（Phase 2 已在客户端固化该语义）。

---

### 4.3 ADR-003 — Authorization 与令牌（对应 D-06、D-07）

**状态：FROZEN。**

#### 4.3.1 读取流程（FROZEN）

```
Client
  │ ① 请求：media_id + 期望变体 + prefer 策略（携带自身身份凭证）
  ▼
Authorization
  │ ② owner / 显式 Grant / 业务规则（房间成员资格、动态可见性、公开）
  │ ③ fail-closed；写审计（不含摘要/不含令牌明文）；判定可缓存但 TTL 极短且有撤销版本
  ▼
Media Resolver
  │ ④ media_id → MediaObject（校验状态 ACTIVE、未隔离、隔离域匹配）
  ▼
Variant Resolver
  │ ⑤ 选档：prefer=auto → 按网络/屏幕/已缓存档位；未就绪 → 回退 poster 或 202+retry
  ▼
Signed URL
  │ ⑥ 签发：绑定 media_id + variant + subject + expire + signature（+ aud_scope/jti/版本）
  ▼
Download
  │ ⑦ 服务端或 CDN 校验签名与（按级别）调用方身份 → 返回字节（支持 Range）
  ▼
Client Cache（Phase 2 已交付）
```

**FROZEN 要点**：

- 授权**永远发生在签发令牌之前**；"持有 URL"不是授权依据（这是对现状 T3 的修正）。
- **默认拒绝**：判定依赖不可用 → 403/503，绝不降级为允许。
- **变体级授权**：Grant 的 `variant_scope` 决定"能看到哪些档位"；"能看缩略图但不能看原图"是一等公民。
- **可实时复核的推导授权**：成员资格/可见性不写永久快照，读取时按 `derived_from` 复核
  （现状 Moments 已是该模式；Matrix 侧保持 token + 房间状态）。

#### 4.3.2 Signed URL 的最小绑定集（FROZEN）

令牌**至少**绑定以下四项（缺一不可），并允许扩展：

| 字段 | 含义 | 理由 |
| --- | --- | --- |
| `media_id` | 对象标识 | 防止令牌被替换对象复用 |
| `subject` | 请求主体（user id）或受众范围（room/audience），**明确区分"人"与"群"** | 可撤销、可审计、可按级别决定是否可转发 |
| `expire` | **服务端写入**的绝对过期时间 | 修正"客户端 `expires_in` 决定 TTL"（T3/T4） |
| `signature` | 服务端密钥签名（含密钥版本号） | 防伪造；支持轮换 |
| `variant`（扩展，FROZEN 必须） | 被授权的档位 | 变体级授权的最小实现 |
| `jti` + `max_uses`/`single_use`（扩展，按级别） | 单次/限次使用 | 高敏感内容的防转发手段 |
| `grant_version`（扩展，按级别） | 授权版本，撤销时递增 | 让"撤销立即生效"成为可能 |

**禁止**：把摘要、明文文件名、存储路径、内部 key 放进令牌（令牌可能被记录在日志/历史里）。

#### 4.3.3 URL 可否在同一受众内转发（FROZEN：分级回答）

| 级别 | 是否允许受众内转发 | 风险 | 如何实现/限制 |
| --- | --- | --- | --- |
| **`audience`**（群聊媒体、朋友圈可见动态、公开封面/头像版本） | **允许**（FROZEN） | ① 受众成员可把 URL 转给受众外的人（在 TTL 内有效）；② 无法按人撤销；③ CDN 会把该 URL 视为共享对象 | 换取 CDN 命中率与实现简单性。约束：**短 TTL**（策略见 §4.3.4）+ `aud_scope` 校验 + 边缘限速 + 异常检测 + 对象级/受众级封禁；一旦需要按人撤销，必须升级为 `private` 级别 |
| **`private`**（1:1 聊天附件、E2EE 原始文件、闪照、原图） | **禁止**（FROZEN） | 若允许，URL 泄露 = 内容泄露，且撤销不可能 | **实现**：令牌中的 `subject` 必须与调用方身份一致——下载端点要求 `Authorization`（会话/JWT）并把其 `sub` 与令牌 `subject` 比对；不匹配 → 403（且不泄露对象是否存在）。附加手段：单次使用（`single_use`）、极短 TTL、设备/会话弱绑定、令牌使用次数与来源 IP 段异常告警 |
| **`public`**（无差别可读的版本化素材） | 允许（无隐私含义） | 无（本就公开） | 长 TTL + 版本化路径 + 公共缓存；版本切换即失效旧 URL |

**对"禁止转发"的诚实说明**：`private` 级别的"禁止"是**降低**而非消除风险。
持有有效会话的攻击者仍可在 TTL 内自行下载；本冻结的承诺是"**转发一个 URL 给他人，他人无法使用**"。

#### 4.3.4 TTL 策略（FROZEN 为策略，数值 DEFERRED）

> **不允许客户端决定 `expires_in`**：请求参数一律忽略；TTL 由服务端按"内容类别 + 级别 + 用途"决定。

| 内容类别 | 级别 | TTL 相对策略（FROZEN） | 备注 |
| --- | --- | --- | --- |
| poster / 缩略图 | audience/public | **最长档**（可被 CDN 长缓存） | 尺寸小、敏感度低、复用率最高；长 TTL 换命中率 |
| 普通图片（朋友圈/群聊正文档） | audience | **中档** | 兼顾缓存命中与撤销窗口 |
| 视频档位（360/720/1080） | audience | **中档**，播放期允许刷新 | 需覆盖一次完整播放 + 拖动；用刷新端点续期而非长 TTL |
| 原图 / `read_original` | private | **短档 + 可选单次** | 最高敏感度 |
| E2EE 1:1 附件 / 私密文件 | private | **最短档** | 令牌泄露后果最重 |
| 公开素材（版本化） | public | **长档 + immutable** | 版本号变化即失效 |

**数值未冻结**（DEFERRED-3）：具体秒数由实现阶段按"用户体验（视频拖动/弱网）+ 撤销窗口"实测平衡后写入配置；
本文档只冻结"**相对关系**"（public ≥ audience ≥ private；poster ≥ image ≥ video ≥ original）与"服务端唯一决定"。

#### 4.3.5 授权模型（FROZEN 字段）

```
Grant {
  media_id, variant_scope[],
  subject_type ∈ {user, room, audience, public, service}, subject_id,
  permission ∈ {read, read_original, list, delete, admin},
  derived_from { rule ∈ {owner, room_membership, moment_visibility, admin, public}, ref },
  expires_at, single_use, grant_version, issued_by, created_at, revoked_at
}
```

**判定顺序（FROZEN）**：owner/admin 短路 → 显式 Grant → 业务规则推导 → 默认拒绝。
**授权缓存**：允许，但 TTL 极短且必须支持撤销失效；不得把"缓存命中"当作绕过复核的理由。

---

### 4.4 ADR-004 — Matrix 兼容与接入边界（对应 D-08、D-09、D-10、D-12 的兼容部分）

**状态：FROZEN。**

#### 4.4.1 兼容方式（FROZEN：永不迁移字节 + 惰性建索引 + 双读）

用户要求冻结"双写 / 渐进迁移 / lazy migrate / 永不迁移"四选一。**冻结结论**：

| 维度 | 决定 | 理由 |
| --- | --- | --- |
| **字节** | **永不迁移**（no byte migration） | Chat 字节是 E2EE 密文，`mxc://` 写在**不可变的历史事件**里；搬移/重加密会破坏历史消息。业务侧字节也无需搬移（路径即身份） |
| **元数据** | **lazy migrate（惰性建索引）** | 首次访问或后台批处理时建立 `MediaObject/Blob/Variant/Reference` 行；**不启动全量扫描**（与 Phase 2 客户端索引同一原则） |
| **写入路径** | **不对字节做双写**（no dual-write of bytes） | Chat 继续走 Matrix upload；业务继续走 begin/put/complete。双写字节会立刻产生两份副本，与目标相反 |
| **读取路径** | **双读（dual-read）**：平台元数据优先，缺失则回退既有路径 | 保证"旧数据永远可读"（P9）；任何时候关掉平台都能回到现状 |
| **引用** | 允许对**业务表**做惰性引用回填（Moments/Avatar 的 key → `Reference`） | 这是回收能力的来源；E2EE 域不尝试回填"消息引用"（不可数） |

#### 4.4.2 Adapter（FROZEN 结构，不实现）

```
        Chat / File (E2EE)            Moments / Avatar / Renders
                │                              │
      MatrixMediaGateway                BusinessMediaGateway
        （适配器，只读+索引）              （适配器，读写）
                │                              │
                └──────────┬───────────────────┘
                           ▼
                     MediaGateway
        （统一：对象/变体/引用/授权/令牌/配额/指标）
```

- **`MatrixMediaGateway` 不得修改 Matrix 协议或上传接口**：它只做"把既有 Matrix 媒体**索引化**"与
  "复用既有密文摘要索引"；对 Synapse 的改动保持在**既有补丁语义**内，Phase 4 不要求新增 Synapse 补丁。
- **`BusinessMediaGateway`** 负责明文域的会话/校验/内容寻址/引用/GC。
- 两个 Adapter 之间的**唯一**共享是平台元数据与令牌签发，**不共享字节空间**（ADR-001）。

#### 4.4.3 Moments 接入边界（D-09）

| 项目 | 决定 |
| --- | --- |
| Moments 是否 Phase 1 接入 | **是（FROZEN）**。理由：① 已经是明文域，服务端可直接算摘要，零隐私代价；② 已经有真实的孤儿/泄漏问题（动态删除不删字节、封面替换不删旧对象、`SCANNING` 滞留、渲染产物无主）；③ 客户端已把 Moments 媒体放进本地对象库，语义一致 |
| 接入方式 | **新建写路径 + 旧路径保留**：Phase B 起新上传经 `BusinessMediaGateway`；旧 `media://` 与旧接口在迁移窗口内继续可用；既有对象惰性建索引 |
| 不做 | 不归一化演绎版参数（不改发送字节）；不改朋友圈可见性规则；不改 Moments API 的既有语义（可新增端点，不破坏旧端点） |

#### 4.4.4 Avatar 接入边界（D-09）

| 项目 | 决定 |
| --- | --- |
| Avatar 是否延期 | **延期（DEFERRED-4）**，Phase 4 **不得**把头像迁入平台对象空间 |
| 理由（逐条，用户要求"不要为了统一强行接入"） | ① **TTL/刷新语义**：头像按 `avatar:<userId>:<version>` 缓存、30 天 TTL、版本即失效；平台的对象/授权模型是为"不可变内容 + 显式撤销"设计的，与"高频覆盖写"语义不同；② **高刷新**：头像变更频繁，若进平台会产生大量 short-lived 对象与引用，GC 成本高、收益低；③ **CDN/可见性**：头像本质是"公开版本化素材"（`public` 级别），已有 client 侧 Query-stripped 版本键，接平台反而要先解决"公开授权 vs 私有对象"的语义冲突；④ **现状还有重复**：worker 会把头像再复制一份到 Matrix，这个重复应当**单独优化**（去掉复制），而不是顺手并进平台；⑤ 头像不是 E2EE（README 明确），也不共享平台收益（去重收益≈0）。 |
| Phase 4 允许的有限动作 | 允许把头像纳入**指标/配额口径**与**孤儿对象清单**（可观测性），但**不允许**改变其存储位置、TTL 语义与读取路径 |

#### 4.4.5 Video Pipeline 边界（D-10）

| 域 | 谁生成变体 | 决定 |
| --- | --- | --- |
| **E2EE 视频（Chat/群/文件）** | **发送端客户端（FROZEN）** | 服务器**不能**解密 ⇒ 不可能生成 poster/preview/档位。冻结流程：`Sender: original → poster → preview → compressed variant → encrypt → upload`（现状已完全符合：客户端转码 640px/1.2Mbps + poster 抽帧 + 确定性加密后上传） |
| 接收端生成 | **禁止**作为第一阶段方案 | 接收端生成可以省发送端算力，但引入"同一条消息不同用户看到不同档位/不同字节"的语义分叉，且重复计算昂贵；列为 DEFERRED-5 |
| 明文域视频（Moments 视频等） | **服务端转码（允许，Phase 4 后半/延后）** | 服务端有明文，可做 360/720/1080 + preview；但需要独立转码 worker + 队列 + 限额；**不阻塞** Phase 4 主线（DEFERRED-6） |
| 变体命名与"发送端产出"的一致性 | **FROZEN**：发送端产出的每一种字节都是一个独立 `Variant`（不同密文 ⇒ 不同 blob），平台只记录族谱，不合并 | 确保"一个逻辑视频 = 一个 MediaObject + 多个 Variant（poster/preview/compressed/original）"，即使它们来自客户端 |

**E2EE 渐进播放的现实结论（FROZEN 表述）**：Telegram 级的"边下边播"在 E2EE 下**只能**依赖发送端预先产出
`preview` 短片与多档位；服务端**永远**只能是"字节搬运 + 授权 + 分发"。产品若要求更强体验，
必须接受"发送端多算一点、上传多一点"的成本（该取舍属 DEFERRED-7，但技术边界已冻结）。

#### 4.4.6 CDN 模型（D-12）

| 项目 | 冻结内容 |
| --- | --- |
| 链路 | **FROZEN**：`Storage → Media Gateway → CDN → Client`（CDN 永远在 Gateway 之后，绝不直连裸存储） |
| 权限校验位置 | **签发前**（Gateway 内）完成全部授权；CDN **不理解权限**，只认签名 URL/Cookie 与 TTL |
| URL 签名 | **FROZEN**：至少绑定 `media_id + variant + subject/aud_scope + expire + signature`（§4.3.2） |
| 缓存控制 | **FROZEN 分级**：`public`（可长缓存、版本化、immutable）→ `audience`（按受众级 URL 缓存，命中率高）→ `private`（**不进共享缓存**，只做 TLS/连接复用/Range 透传） |
| Variant 选择 | **FROZEN**：选档发生在 Variant Resolver（服务端），CDN 只缓存"已选定的档位 URL"；客户端 `prefer` 只影响选档，不影响缓存键语义 |
| E2EE 与 CDN | **FROZEN**：密文对 CDN 是不透明字节，**允许**缓存"受众级"E2EE 内容（群聊/群文件）；**禁止**把 1:1/private 内容变成公共可缓存 URL |
| 不实现 | 本阶段不选厂商、不改 nginx/CDN 配置、不实现边缘逻辑 |

---

### 4.5 ADR-005 — Upload Engine 边界（对应 D-11、D-15）

**状态：FROZEN。**

#### 4.5.1 边界决定：Upload Engine 是**独立子系统**

| 项目 | 决定 |
| --- | --- |
| 1GB+ 视频属于谁 | **独立 Upload Engine**（FROZEN）。Media Engine 只消费"已提交的 blob"，不负责分片/续传/断点记账 |
| 为什么独立 | ① 上传是**传输问题**（会话、分片、幂等、续传、并发、弱网），与媒体语义（对象/变体/授权）正交；② 现状的 50 MiB 天花板是**上传能力问题**，修它是"加一条并行通道"，不需要动 Matrix 协议；③ 独立后可以单独限流/限额/降级，不影响媒体读取 |
| 与 Matrix 的关系 | **不改 Matrix 上传接口**：Upload Engine 产出的 blob 由 `MatrixMediaGateway` 映射为可被 `mxc://` 读取的媒体（Phase B/C 的对接点）；旧上传路径**永久保留** |
| 与 E2EE 的关系 | **FROZEN 约束**：客户端必须**先加密再分片**；确定性 CTR 下若按分片加密，必须保证第 k 片首块的计数器 = 全局偏移/16（否则密文与单次上传不同 ⇒ 破坏去重）。**推荐实现**：整文件流式加密，只对密文流分片 |

#### 4.5.2 Upload Engine 的冻结功能集（设计级，不实现）

```
UploadSession { upload_id, owner, kind, declared_size, declared_mime,
                envelope{mode,version}, part_size, uploaded_parts[], status,
                expires_at, idempotency_key }
Chunk         { part_number, size, transport_digest(client), server_verified }
Resume        { GET session → 已收分片清单；只补缺失片 }
Checksum      { 分片级 transport_digest（服务端复算）+ 全局权威摘要（服务端组装时自算）}
Encrypt       { E2EE：客户端先加密（确定性/随机信封）→ 只上传密文；明文域：服务端可选做服务端加密（DEFERRED-8）}
Commit        { complete（幂等）→ 校验 → 组装 → 建 blob → 建对象/变体 → 引用 }
Abort/Expire  { 删除临时分片；过期会话必须可被 GC 回收 }
```

**FROZEN 的行为要求**：

1. **不提供**"只用摘要查询是否存在"的客户端预检接口（§4.2.3）。
2. **幂等**：create/complete 必须 `Idempotency-Key`；分片 PUT 幂等（同分片同内容可重放）。
3. **失败可续**：会话在 TTL 内可续传；应用被杀/换网后可恢复。
4. **绝不在组装完成前发布 `media_id`**（防止"指向不存在字节的 ID"；与现状补丁的 pending 语义一致）。
5. **限流与配额**：单用户并发会话数、在途字节、每秒分片数都必须可限。

#### 4.5.3 大文件能力冻结（D-15）

| 能力 | 是否在 Phase 4 范围 | 说明 |
| --- | --- | --- |
| chunk upload | ✅ 是（Phase D） | 服务端下发分片大小；支持 1GB+ |
| resume | ✅ 是（Phase D） | 断点续传是 1GB+ 的**前提** |
| background upload | ✅ 客户端职责，服务端只保证"会话可续 + 幂等" | 服务端不假设客户端在线 |
| checksum | ✅ 是（分片级 + 全局权威） | 客户端摘要不可信（§4.2.1） |
| 上限调整 | ⚠️ 需部署变更（nginx/Synapse 配置），**不是**代码改动 | 现状实际生效上限 = Synapse `max_upload_size: 50M` |

---

### 4.6 ADR-006 — 删除、生命周期与状态机（对应 D-13、D-14、D-05 的生命周期部分）

**状态：FROZEN。**

#### 4.6.1 MediaReference 冻结模型（D-05）

业务**永不直接绑定媒体**，只能通过引用（这是"一个媒体被多处使用"与"安全删除"的前提）：

```
message ─┐                        ┌─ media_reference ──▶ MediaObject
moment  ─┼─▶ media_reference ─────┤
profile ─┘                        └─ （business_type / business_id 决定业务语义）
```

**冻结字段（字段名 FROZEN）**：

| 字段 | 类型/取值 | 说明 |
| --- | --- | --- |
| `reference_id` | 不透明 ID | 引用自身身份（可审计、可幂等） |
| `media_id` | 不透明 ID | 指向 `MediaObject`；**引用不指向 Blob/Variant**（变体由 `variant_kind` 表达） |
| `business_type` | `chat_message \| group_message \| moment \| moment_comment \| moment_cover \| avatar \| file \| announcement \| uploader \| system` | 业务种类（`uploader` 用于承载现状的"上传者持有"语义） |
| `business_id` | 业务对象 ID | 事件 ID / 动态 ID / 用户 ID / 会话 ID |
| `permission_scope` | `private \| audience \| public`（+ 可选 `room_id`/`audience_ref`） | 该引用**建议**的可见性级别；最终判定仍走 ADR-003，本字段只是策略输入 |
| `created_at` | 时间戳 | 引用建立时间（用于对账与保留期计算） |
| `state` | `active \| released` | 引用生命周期（FROZEN 状态名） |
| `ref_kind` | `observed \| declared` | 服务端可观测 / 客户端声明（E2EE 不可数的诚实表达） |
| `variant_kind` | 可空 | 该引用关心的档位；空 = 跟随主档 |
| `released_at` / `release_reason` | 可空 | 解引用时间与原因枚举（`message_deleted \| moment_deleted \| avatar_replaced \| retention \| user_delete \| moderation`） |

**FROZEN 规则**：

1. 同一 `(media_id, business_type, business_id)` 只允许**一条 `active` 引用**（幂等）。
2. 引用计数 = `active` 引用数；**必须可从引用表重算**（缓存列可丢，真相源是引用表）。
3. **删除 = 解引用**，绝不删除对象（§4.6.3）。
4. `declared` 引用只作提示，**不得单独决定删除**（ADR-001/Phase 3 设计 §6.3 的保守策略）。
5. E2EE 域**不尝试**回填"消息引用"（不可数）；其回收依据是 observed 引用 + 保留期下限。
6. 引用写入必须使用一次性 `reference_token`（防"过期 URL 洗白成永久引用"，§5.1 S6）。

#### 4.6.2 删除语义（FROZEN）

**删除不是删除 Object，而是解除引用**：

```
Remove Reference
      │
      ▼
Check References  ── 仍有 ACTIVE 引用 ──▶ 什么都不做（对象保持 ACTIVE）
      │ 无 ACTIVE 引用
      ▼
Mark Orphan       （记录 unreferenced_at；对象仍可被复用/重传命中）
      │  超过保留期（+ E2EE 下限）且无 pin / 无在途上传
      ▼
GC（DELETING → 物理 unlink → DELETED）
```

**FROZEN 状态集**：

| 状态 | 含义 | 允许出边 |
| --- | --- | --- |
| `ACTIVE` | 有活跃引用（或有下限保护），可读、可被引用 | → `ORPHAN`（引用归零）；→ 隔离（正交属性，见下） |
| `ORPHAN` | 无活跃引用，仍在保留期内（可被重传复用，可被重新引用） | → `ACTIVE`（重新引用/重传命中）；→ `DELETING`（保留期到） |
| `DELETING` | 已进入回收流程（先标记、后 unlink；可重试、可恢复） | → `DELETED`（成功）；→ `ORPHAN`（失败回滚/需人工） |
| `DELETED` | 字节已删除，摘要位释放（必要时留墓碑） | 终态 |

**正交属性（不新增状态）**：

- `QUARANTINED`（隔离）：**布尔属性**而非状态，作用于对象/摘要，使任何状态下的对象都不可读；
  且**保留摘要墓碑**以防"换个用户重传被封禁内容"（现状 Synapse 语义，本冻结继承）。
- `PINNED`（使用中）：转码中、下载中、上传组装中的对象**不得**被 GC；计数式（同 Phase 2 的 pin/lease）。

#### 4.6.3 GC 的冻结约束

1. **先标记后删除**：进入 `DELETING` 必须先持久化（崩溃后能继续/回滚），绝不"删了再记账"。
2. **保护集**：有 `ACTIVE` 引用、未过保留期、`PINNED`、有活跃上传会话、`QUARANTINED`（保留墓碑）→ 一律跳过。
3. **E2EE 下限**：E2EE 域引用不可数 ⇒ 回收必须满足"保留期下限"（策略冻结为"存在下限"，**数值 DEFERRED-9**）。
4. **批量 + 可中断 + 可 dry-run**：必须有 dry-run 报告与每轮审计（现状完全没有 GC）。
5. **绝不级联删引用**：GC 不修改业务表；业务表的删除由业务自己触发"解除引用"。
6. **配额上限**：GC 单轮有速率上限，避免 IO 风暴（与转码/上传争抢）。

#### 4.6.4 Variant 生命周期（FROZEN）

```
pending ─▶ processing ─▶ ready
   │            │
   │            └─▶ failed（终态，客户端降级到下一档）
   └─▶ skipped（不适用：GIF 无缩略图、源分辨率不足、策略禁止）
```

- `ready` 之前**不可读**（客户端收到 202 + retry_after，或回退 poster/低档）。
- `failed` 必须**显式且可观测**（含不含内容的 reason 枚举），否则客户端会无限重试。
- **新参数 = 新 generation**，不覆盖旧 variant；读取默认取最新 ready（客户端缓存键包含 generation）。
- Variant 的字节在 `Blob` 层共享（ADR-002 §4.2.5）。

#### 4.6.5 `SCANNING` 状态的冻结决定（D-14）

> 现状：`moment_media_uploads.status` 有 `SCANNING`，但**全仓库没有生产者**；且 `put_content` 不校验过期，
> 上传可永久滞留（审计 A15）。用户要求决定"保留还是删除设计"。

**FROZEN 决定：保留该状态，但必须同时具备"生产者 + 超时兜底"，否则禁止使用。**

```
UPLOAD ─▶ (SCANNING) ─▶ READY ─▶ (AVAILABLE)
            ▲ 可选阶段：仅当扫描/审核链路启用时存在
```

| 规则 | 内容 |
| --- | --- |
| 状态存在的条件 | 必须有**明确的生产者**（内容扫描/合规审核钩子）。若平台未启用扫描，则**必须** `UPLOAD → READY` 直通，**禁止**停留在 `SCANNING` |
| 超时兜底 | `SCANNING` 必须带截止时间；超时后自动进入 `READY`（若扫描未启用）或进入 `ORPHAN`（若扫描判定失败/被拒）——**绝不允许无限滞留** |
| 可读性 | `SCANNING` 期间对象**不可对外可读**（fail-closed），但**不得**因此阻塞上传者的后续操作 |
| 存量数据 | 迁移时必须把**现存滞留的 `SCANNING` 行**视为孤儿候选：要么补扫描结果，要么置为可回收（不得继续堆在库里） |
| 与 `QUARANTINED` 的关系 | 两者不同：`SCANNING` 是"待判定"，`QUARANTINED` 是"已判定不可读"。实现时不得互相复用 |
| E2EE 域 | 服务端**无法**扫描 E2EE 内容 ⇒ E2EE 域**不存在** `SCANNING` 阶段（不得为对称美观引入） |

---

## 5. Security Model

### 5.1 Threat Model（用户要求的七项，逐项给出威胁、冻结对策、残余风险）

| # | 威胁 | 攻击者能力假设 | 冻结对策 | 残余风险（明确记录） |
| --- | --- | --- | --- | --- |
| S1 | **hash 泄露 / 存在性探测** | 能观察 API 时序与响应差异；拥有候选文件集 | ① E2EE 域只用 `ciphertext_digest` 且永不外泄；② 明文域摘要永不入 API/URL/日志，对外 ETag 用 HMAC 派生；③ **不提供**按摘要查询的客户端接口；④ 去重门槛（小文件不去重）；⑤ 客户端不得提交明文摘要用于 E2EE 去重 | 在线确认攻击**无法根除**（有去重即有预言机）；确定性加密的可链接性已在 ADR-0060 被接受；长度/时序仍可观察 |
| S2 | **URL 泄露** | 拿到 URL（日志、Referer、截图、转发、代理） | ① 服务端强制 TTL（忽略客户端 `expires_in`）；② 分级转发策略（§4.3.3）：private 级别必须 `subject` 与调用方身份一致；③ `single_use`/`max_uses`；④ `no-referrer`；⑤ 令牌不含摘要/路径/文件名 | private 级别在 TTL 内仍可被"授权者本人"泄露；audience 级别**接受**受众内转发（换取 CDN 效率） |
| S3 | **越权访问** | 已认证的无关用户 / 被移出房间的用户 / 猜测 media_id | ① fail-closed 判定顺序；② 变体级授权；③ 实时复核成员资格/可见性；④ 不透明 ID（不可枚举）；⑤ 授权缓存极短且可撤销 | 短 TTL 内已签发令牌仍有效；业务规则判定依赖 Matrix/Moments 可用性（不可用即拒绝，可能造成"可用性"抱怨） |
| S4 | **replay（重放）** | 抓包重放上传/下载请求 | ① 上传 create/complete 强制 `Idempotency-Key`（同 key 同 payload 幂等返回，不同 payload 409）；② 分片 PUT 幂等且 etag 必须一致；③ 下载令牌 `jti` + `single_use`/`max_uses`；④ 业务写操作沿用既有幂等 + 审计 + Outbox | 幂等键本身可被用来"试探"（需限流与审计）；无限次令牌在 TTL 内天然可重放 |
| S5 | **token 盗用** | 恶意 App/中间人/共享设备拿到令牌或会话 | ① 短 TTL；② private 级别绑定调用方身份（仅有 URL 无用）；③ `grant_version` 支持即时撤销；④ 异常检测（同 token 多 IP/多 UA）；⑤ 令牌不落日志 | 设备被完全控制时无法防御（属客户端安全域）；TLS 终止点（宿主 Caddy + nginx）需保持受信 |
| S6 | **reference 污染** | 把他人对象/过期 URL 挂到自己的业务对象上 | ① 引用写入必须使用**一次性 `reference_token`**（用途绑定、单次、短 TTL），**不复用下载令牌**（修正现状"过期 URL 洗白成永久引用"）；② 写入时校验 owner/状态/变体范围；③ 引用与对象状态联动（隔离对象的所有引用立即不可读）；④ 引用操作写审计 | 同一用户把同一对象合法挂到多个业务对象上是**允许**的（必须正确计数，不得当越权处理） |
| S7 | **CDN abuse** | 盗链、刷带宽、把受众 URL 大规模外泄 | ① 只有 public/audience 进共享缓存，private 不进；② 边缘限速与并发限制；③ request collapsing 防回源放大；④ 对象/受众级封禁；⑤ 回源率与带宽告警 | audience URL 外泄会变成"准公开 CDN"（需短 TTL + 异常检测）；现状**完全没有边缘限流**，属 Phase 4 的部署项 |

### 5.2 安全不变量（FROZEN，Phase 4 不得违反）

| # | 不变量 |
| --- | --- |
| I1 | 平台永不接收/存储/比较 E2EE 域的明文摘要，永不持有附件密钥 |
| I2 | 客户端提供的任何摘要永不作身份、永不作去重键、永不作授权依据 |
| I3 | 明文域摘要与密文域摘要永不互相比较，永不共用一个索引分区 |
| I4 | `media_id`/`blob_id` 不是摘要，且不可猜测 |
| I5 | 授权在签发令牌之前完成；CDN 不参与授权判定 |
| I6 | 任何策略依赖失败都必须拒绝（fail-closed），不得降级为允许 |
| I7 | 删除先解引用；引用归零不等于立即删除；GC 尊重保留期、pin 与隔离墓碑 |
| I8 | 摘要、密钥、明文文件名、存储路径永不进入日志/URL/推送/指标标签 |
| I9 | 每个新能力必须有"关闭即回到现状"的开关，且关闭不丢数据 |
| I10 | 旧 `mxc://` 与旧 `media://` 永久可解析；不重加密、不搬字节、不改事件 |

---

## 6. Performance Goals

> 本节是**目标**（含验收方式），不是测量结论。唯一实测基线见下方"现状基线"。

### 6.1 现状基线（实测，勿当作生产结论）

| 项 | 实测 | 出处 |
| --- | --- | --- |
| 200 VU 同步 | 6/6 轮 PASS | `docs/verification/2026-09-10-media-capacity-runtime.md` |
| 500 VU 同步 | 首次升档 2 轮 FAIL、预热后 4 轮 PASS，**未验收** | 同上 |
| 千人/万人 | **从未验收** | 同上 |
| 生产宿主 | 8 vCPU / ≈7.9 GB RAM / 174 GB 可用（同机还有其他服务） | `docs/verification/2026-09-10-media-framework-production.md:12-13` |

### 6.2 目标指标（FROZEN 为"目标 + 验收方法"；数值为工程目标，需实测确认）

| 场景 | 目标 | 验收方法 |
| --- | --- | --- |
| **缩略图 / preview 图片：本地缓存命中** | **< 100 ms**（P50），P95 ≤ 300 ms | 客户端埋点（Phase 2 已有 `cache_lookup_ms`/`index_lookup_ms`）+ 真机 |
| **poster（视频封面）：缓存命中** | **< 50 ms**（P50） | Phase 1 pipeline 的诊断计数 + 真机 |
| **图片（冷，CDN 命中）** | 首字节 P50 ≤ 200 ms、P95 ≤ 800 ms | CDN 边缘日志 + 客户端首字节 |
| **视频：preview 首字节** | 可播放 ≤ 2 s（本地已有 poster 时首帧 ≤ 1 s） | 播放器埋点（起播时间、卡顿次数） |
| **视频：拖动** | ≤ 500 ms（Range 生效） | 播放器埋点 |
| **千人群（1000 成员）** | ① 消息时间线首屏**不因媒体变慢**（媒体懒加载，只处理可见窗口）；② 单条媒体在群内的**源站回源 ≤ 1 次/边缘节点**；③ 群媒体峰值带宽由 CDN 承担（回源率 ≤ 5%） | 容量脚本（`scripts/loadtest` 场景扩展）+ CDN 侧指标；沿用 200/500/1000 分档验收 |
| **万人并发** | 源站只承担 ≤ 5% 流量；令牌签发 P95 ≤ 50 ms；错误率 < 0.1% | 压测 + CDN 指标 + 服务端指标 |
| **上传（1 GB+）** | 弱网可续传：中断后恢复不重传已完成分片 | 断点续传用例（Phase D 验收） |

### 6.3 性能设计约束（FROZEN）

| # | 约束 |
| --- | --- |
| PF1 | 冷热分层必须存在：热点走 CDN/边缘，源站不承担重复回源 |
| PF2 | 元数据路径**禁止**每请求一次同步写（`last_access` 必须批量/去抖，与 Phase 2 同构） |
| PF3 | 授权判定允许极短缓存，但必须有撤销通道 |
| PF4 | GC / 转码 / 上传组装必须限速、可中断、低优先级，不得与读取争抢 IO |
| PF5 | 媒体写路径的全局串行锁（现状）**在测量之前不得分片**；分片必须保持"同摘要互斥" |
| PF6 | 客户端侧：媒体处理必须有全局并发上限（现状视频并发 1 / 媒体发送并发 3），服务端不得假设客户端可高速并发上传下载 |

---

## 7. Migration Plan

### 7.1 五阶段（FROZEN 顺序与边界）

```
Phase A  Gateway abstraction
   · 只读适配：MatrixMediaGateway / BusinessMediaGateway 建立"媒体清单视图"
   · **不改变任何写入路径**；不搬字节；不建新表（可先用视图/只读投影）
   · 出口条件：新旧读取结果一致（暗读对账）；关掉即回到现状

Phase B  Reference system
   · 业务域接入：新上传经 BusinessMediaGateway（内容寻址 + 引用 + 审计）
   · 明文域引用**惰性回填**（首次访问/后台批处理）；E2EE 域只接 observed 引用
   · 出口条件：引用计数可从业务表重算；删除=解引用；无孤儿增长

Phase C  Variant resolver
   · 变体模型与选档；poster/preview/档位的读取路径统一（未就绪时的降级语义）
   · E2EE 变体由发送端产出（ADR-004 §4.4.5），平台只登记
   · 出口条件：客户端可按 prefer 选档；未就绪不阻塞首屏

Phase D  Upload engine
   · 会话式分片上传 + 续传 + 校验 + commit（独立子系统，ADR-005）
   · 出口条件：1 GB+ 弱网可续传；旧上传路径仍可用

Phase E  Remote optimization
   · CDN 分级 + 签名 URL + 防盗链 + 边缘限速（ADR-004 §4.4.6、ADR-003）
   · 出口条件：回源率与带宽达标；private 级别不进共享缓存
   · **注意**：全球去重、对象存储迁移、多区域**仍不在 Phase E**（属 §8 DEFERRED）
```

### 7.2 每阶段的不变量与回退（FROZEN）

| 阶段 | 回退动作 | 数据影响 | 破坏性 |
| --- | --- | --- | --- |
| A | 关闭适配层 | 无（只读） | 无 |
| B | 关闭新写路径，回到旧接口；已写元数据保留可读 | 只增元数据 | 无 |
| C | 停止选档，回退到"单档 + 既有路径" | 无（变体行保留） | 无 |
| D | 关闭新上传通道，旧通道继续服务 | 会话临时数据可回收 | 无 |
| E | 回退到直连源站（关闭 CDN） | 无 | 无 |

**FROZEN 硬约束**：禁止破坏性迁移；schema 变更走 expand-migrate-contract；字节永不移动；
每阶段必须以"关掉开关即回到现状且旧数据可读"为验收前提。

### 7.3 每阶段的验收证据（FROZEN）

1. 一致性对账（对象/引用/磁盘三方计数 + 抽样摘要）；
2. 容量回归（200 / 500 / 1000 VU，**通过必须绑定明确 SLO**，现状脚本没有延迟 SLO）；
3. 回退演练（关开关 → 旧路径可读 → 再打开）；
4. 安全回归（越权、过期令牌、引用污染、隔离传播四类用例）；
5. 指标看板（§6.2 与 §6.3 所需指标的落地）。

---

## 8. Deferred Decisions（**未冻结**，Phase 4 不得实现）

| # | 未冻结项 | 为什么不能现在冻结 | 需要的输入 |
| --- | --- | --- | --- |
| DEFERRED-1 | **全球去重（Option C）/ 跨用户明文去重** | 隐私（存在性/确认攻击）、跨租户滥用与法务耦合、无法承诺"单用户彻底清除" | 隐私 + 安全 + 产品评审；结论需新 ADR |
| DEFERRED-2 | 去重门槛的具体数值（最小尺寸、热度阈值） | 需实测命中率与攻击面权衡 | 上线后度量 + 隐私评审 |
| DEFERRED-3 | TTL 的具体秒数 | 需实测"视频拖动/弱网体验"与"撤销窗口"的平衡 | 实测 + 安全评审 |
| DEFERRED-4 | **Avatar 迁入平台对象空间** | 与头像 TTL/版本/高频刷新语义冲突，收益≈0（§4.4.4） | 单独 ADR；先做"去掉 Matrix 头像副本"的独立优化 |
| DEFERRED-5 | 接收端生成 E2EE 变体 | 会造成同消息不同用户看到不同档位；重复计算昂贵 | 产品 + 端侧性能评估 |
| DEFERRED-6 | 明文域服务端转码流水线（360/720/1080 + preview） | 需独立 worker/队列/限额与成本模型；不阻塞主线 | 成本评估 + 容量测试 |
| DEFERRED-7 | "发送端多算一点"的具体参数（preview 时长/码率/档位） | 属产品体验与流量成本的取舍 | 产品决策 + 弱网实测 |
| DEFERRED-8 | 明文域服务端加密（如未来把 Moments 改为加密存储） | 会改变可见性/审核/搜索能力，属产品级变更（本阶段禁止改 E2EE） | 产品 + 合规评审 |
| DEFERRED-9 | E2EE 保留期下限 / `last_access` 延长上限的具体数值 | 法务、合规、成本与"用户期望永久可读"的冲突 | 法务 + 产品决策 |
| DEFERRED-10 | 索引层 HMAC（C2）或受信盲去重（C3） | 涉及新密钥资产/新服务与协议，复杂度高 | 隐私评审 + 工程评估 |
| DEFERRED-11 | 内容哈希黑名单扫描（合规） | 黑名单本身即存在性探测；E2EE 域不可扫描 | 法务 + 隐私评审 |
| DEFERRED-12 | 对象存储迁移（S3/OSS）、多区域、CDN 厂商选型、多副本与备份自动化 | 属 Phase 3 后半/运维决策；需成本与备份恢复演练 | 运维 + 成本评审 |
| DEFERRED-13 | 管理/客服的媒体读取与删除端点 | 需要新的 RBAC 与审计设计（现状**完全没有**这类端点） | 安全 + 运维评审 |
| DEFERRED-14 | 配额的具体数值与计费口径（含"是否按存储计费"） | 需成本模型与产品定价决策 | 产品 + 财务 |
| DEFERRED-15 | Phase 4 的 AI 能力（分析/标签/搜索/视频理解） | 属 Phase 4 之后的路线图（Phase 3 设计 §17） | 单独立项 |

**FROZEN 约束**：以上任一项在 Phase 4 中被"顺手实现"，即视为违反本冻结。

---

## 9. Phase 4 Implementation Boundary

### 9.1 Phase 4 **可以**实现（允许范围）

| # | 允许项 | 前置/约束 |
| --- | --- | --- |
| 1 | `MediaGateway` 骨架 + 元数据表（对象/Blob/Variant/引用/Grant/会话/GC 运行） | 仅新增表（expand-only）；不改既有表语义；不改 Matrix schema |
| 2 | `BusinessMediaGateway`：Moments 新写入路径（会话式上传 → 内容寻址 → 引用） | 旧接口保留；`media://` 永久可读；不改可见性规则 |
| 3 | 明文域内容寻址（`plaintext_digest`，**限本用户隔离域内**） | 遵守 ADR-001/102；不得跨用户 |
| 4 | 密文域复用（沿用既有 `ciphertext_digest` 索引与引用语义） | 不新增 Synapse 补丁；不改 Matrix 协议 |
| 5 | 引用系统 + 引用计数 + 对账重算 | E2EE 域只接 observed 引用；不伪造消息数 |
| 6 | 删除/生命周期/GC（ACTIVE/ORPHAN/DELETING/DELETED + 墓碑 + pin + dry-run） | 遵守 ADR-006；含"存量 `SCANNING` 清理" |
| 7 | 授权判定 + Grant + Signed URL（服务端强制 TTL、subject 绑定、分级转发） | 遵守 ADR-003；修掉"客户端决定 TTL""URL 洗白引用" |
| 8 | Variant 模型 + Variant Resolver + E2EE 发送端变体登记 | 不在服务端转码 E2EE 内容 |
| 9 | `MatrixMediaGateway` 只读适配 + 惰性索引 + 双读回退 | **永不迁移字节**；不改事件与协议 |
| 10 | Upload Engine（会话/分片/续传/校验/commit/abort） | 独立子系统；E2EE 先加密再分片且保持 CTR 计数器连续 |
| 11 | 指标/审计/配额**口径**（不含具体数值决策） | 指标标签无 PII；不记录摘要 |
| 12 | CDN 前置准备（签名 URL 形态、缓存分级策略、private 不进共享缓存） | 厂商选型与边缘配置属 DEFERRED-12 |
| 13 | 部署参数调整（nginx/Synapse 上限、边缘限流）——**仅当**该阶段被明确授权执行部署 | 属运维变更，需单独授权与回滚方案 |

### 9.2 Phase 4 **禁止**实现（禁止范围）

| # | 禁止项 | 依据 |
| --- | --- | --- |
| 1 | 修改 Matrix Server 源码/协议、E2EE、Megolm/Olm、媒体上传接口、Moments API 的既有语义、Avatar API | 用户约束；ADR-004 |
| 2 | 修改既有数据库 schema（破坏性变更）或既有列的语义 | AGENTS.md（expand-migrate-contract） |
| 3 | 搬运/重加密/改名旧媒体字节；改写历史事件 | P9；ADR-004 |
| 4 | 把明文摘要交给服务器用于 E2EE 去重；客户端摘要当权威 | I1/I2 |
| 5 | 明文域跨用户去重；全球去重（Option C） | ADR-001；DEFERRED-1 |
| 6 | 服务端解密或转码 E2EE 内容；服务端生成 E2EE preview/档位 | ADR-004 §4.4.5 |
| 7 | 把 Avatar 迁入平台对象空间 | DEFERRED-4 |
| 8 | 在 `private` 级别允许 URL 受众内转发或让其进入共享 CDN 缓存 | ADR-003 §4.3.3 |
| 9 | 用客户端 `expires_in` 或任何客户端参数决定令牌有效期 | ADR-003 §4.3.4 |
| 10 | 提供"按摘要查询是否存在"的客户端接口 | ADR-002 §4.2.3 |
| 11 | 为对称美观在 E2EE 域引入 `SCANNING` 阶段 | ADR-006 §4.6.5 |
| 12 | 无 dry-run / 无审计 / 无 pin 保护的 GC；级联删除业务引用 | ADR-006 |
| 13 | 在未测量的情况下分片媒体写路径的全局锁 | PF5 |
| 14 | 删除或弱化任何既有缓存（客户端或服务端） | 仓库规范 + P7 |
| 15 | 关闭/绕过隔离（quarantine）传播与摘要墓碑 | 安全不变量 I7 + 现状语义 |

### 9.3 Phase 4 的启动前置（FROZEN 检查单）

1. 本冻结文档被批准，且 §8 的 DEFERRED 列表被确认为"不实现"；
2. 明确 Phase 4 的第一步 = **Phase A（Gateway abstraction，只读）**；
3. 取得容量测量环境（复现 200/500 VU 基线）与 CDN/运维决策所需的最少输入；
4. 确认"回退演练"作为每阶段验收硬条件；
5. 确认指标与审计口径（含"指标标签无 PII"）。

---

## 10. Architecture Freeze Report

> 用户要求输出：**ChatFlow Media Engine Phase 3.1 Architecture Freeze Report**，
> 含已冻结决策、未冻结决策、风险、Phase 4 可实现范围、Phase 4 禁止范围。
> 以下为正式报告内容（与 §4–§9 一致，可单独引用）。

### 10.1 已冻结决策（FROZEN）

| ADR | 决策 | 冻结内容摘要 | 对应 D |
| --- | --- | --- | --- |
| **ADR-001** | 媒体隔离 | **第一阶段正式方案 = 隔离域模型**：明文域 = **Option A（用户空间隔离，跨用户零共享字节）**；密文域 = **保留既有密文摘要跨用户复用（受限 Option B）**；**拒绝 Option C 全球去重**。隔离（存哪）与授权（谁能读）严格分离 | D-01 |
| **ADR-002** | Digest / Dedup | 三种 `digest_kind`（`plaintext_digest` / `ciphertext_digest` / `transport_digest`）各自明确"谁算/可信度/谁能访问/用途"；**种类永不互相比较**；**禁止 `plaintext hash == cipher hash`**；客户端摘要永不作权威；不提供客户端存在性查询接口；去重门槛为策略（数值 DEFERRED-2） | D-02、D-03（digest 部分） |
| **ADR-003** | Authorization | 读取流程五段（Client → Authorization → Media Resolver → Variant Resolver → Signed URL → Download）；Signed URL **至少**绑定 `media_id + subject + expire + signature`（+ `variant`，可扩展 `jti`/`grant_version`）；**TTL 由服务端唯一决定**（策略冻结、数值 DEFERRED-3）；转发策略**分级**：`audience` 允许（含风险声明）、`private` **禁止**（以"subject 必须与调用方身份一致"实现）、`public` 无隐私含义 | D-06、D-07 |
| **ADR-004** | Matrix 兼容与接入 | 兼容 = **永不迁移字节 + 惰性建索引 + 读双读 + 字节不双写**；`MatrixMediaGateway` / `BusinessMediaGateway` 适配结构；**Moments 为 Phase 1 接入域**；**Avatar 延期（DEFERRED-4）**；**E2EE 视频变体只能由发送端生成**；CDN 链路 `Storage → Media Gateway → CDN → Client`，**CDN 不参与授权**，缓存分级 | D-08、D-09、D-10、D-12 |
| **ADR-005** | Upload Engine | **独立子系统**（不属 Media Engine 核心）；`UploadSession/Chunk/Resume/Checksum/Encrypt/Commit/Abort`；E2EE **先加密再分片**且保持 CTR 计数器连续；不提供客户端摘要预检；commit 前不发布 `media_id`；chunk/resume/background/checksum 全部在 Phase D 范围（**不实现**于本阶段） | D-11、D-15 |
| **ADR-006** | 删除与生命周期 | 删除 = 解引用（Remove Reference → Check → Mark Orphan → GC）；状态集 **`ACTIVE` / `ORPHAN` / `DELETING` / `DELETED`**；`QUARANTINED` 与 `PINNED` 为**正交属性**；GC 先标记后删除、尊重保留期下限/pin/墓碑、可 dry-run；Variant 状态机 `pending→processing→ready`、`failed`/`skipped` 显式；**`SCANNING` 保留但必须有生产者 + 超时兜底，E2EE 域不得引入** | D-13、D-14、D-05、D-04 |

**同时冻结的横切原则**：P1–P10（§3.2）、安全不变量 I1–I10（§5.2）、性能约束 PF1–PF6（§6.3）、
迁移阶段顺序 A→E 与回退要求（§7）。

### 10.2 决策对照索引（用户清单 D-01…D-15 → 冻结状态）

| D | 主题 | 状态 | 落点 |
| --- | --- | --- | --- |
| D-01 | 媒体隔离策略（A/B/C） | **FROZEN**（明文 A + 密文保留 B 形态，拒绝 C） | ADR-001 |
| D-02 | Digest 模型（三类摘要） | **FROZEN** | ADR-002 |
| D-03 | E2EE 去重边界 | **FROZEN**（不做全球 dedup；密文对象复用仅限确定性信封 + 门槛；明文域只做本用户 dedup） | ADR-002 §4.2.3 |
| D-04 | Object / Blob / Variant 模型 | **FROZEN**（关系：Object 1—n Variant n—1 Blob；Blob 承载摘要与隔离域） | ADR-002 §4.2.5 + Phase 3 设计 §4/§5 |
| D-05 | MediaReference 模型 | **FROZEN**（含 `reference_id/media_id/business_type/business_id/permission_scope/created_at` + observed/declared） | ADR-006 §4.6.1 + Phase 3 设计 §6 |
| D-06 | 权限模型与读取流程 | **FROZEN** | ADR-003 |
| D-07 | Signed URL 绑定与转发策略 | **FROZEN**（分级） | ADR-003 §4.3.2/§4.3.3 |
| D-08 | Matrix 兼容策略 | **FROZEN**（永不迁移字节 + lazy 索引 + 双读） | ADR-004 §4.4.1 |
| D-09 | Moments / Avatar 接入边界 | **FROZEN**（Moments 接入；Avatar 延期） | ADR-004 §4.4.3/§4.4.4 |
| D-10 | Video Pipeline 边界 | **FROZEN**（E2EE 由发送端生成） | ADR-004 §4.4.5 |
| D-11 | Upload Engine 边界 | **FROZEN**（独立子系统） | ADR-005 |
| D-12 | CDN 模型 | **FROZEN**（链路 + 签名 + 缓存分级 + 选档位置） | ADR-004 §4.4.6 |
| D-13 | 删除与生命周期 | **FROZEN**（4 状态 + GC 流程） | ADR-006 |
| D-14 | `SCANNING` 状态 | **FROZEN**（保留 + 生产者 + 超时兜底 + E2EE 不适用） | ADR-006 §4.6.5 |
| D-15 | 大文件能力 | **FROZEN**（chunk/resume/background/checksum，Phase D） | ADR-005 §4.5.3 |

### 10.3 未冻结决策（DEFERRED，Phase 4 不得实现）

完整清单见 §8（DEFERRED-1…15）。**最关键的六项**：

1. **DEFERRED-1 全球去重 / 跨用户明文去重** —— 需隐私、安全、产品评审，且必须出新 ADR。
2. **DEFERRED-2 / DEFERRED-3 数值**（去重门槛、TTL 秒数）—— 策略已冻结，数值待实测与评审。
3. **DEFERRED-4 Avatar 迁入平台** —— 语义冲突且收益≈0；先做"去掉 Matrix 头像副本"。
4. **DEFERRED-6 明文域服务端转码** —— 需独立 worker/成本模型。
5. **DEFERRED-9 保留期数值** —— 法务/合规/成本与"永久可读期望"的冲突。
6. **DEFERRED-12 存储迁移/多区域/CDN 厂商/备份自动化** —— 运维与成本决策。

### 10.4 风险登记（本冻结自身带来的风险，及缓解）

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 | **明文域不做跨用户去重 ⇒ 存储成本高于理论最优** | 磁盘增长更快（尤其多用户上传相同内容） | 明确接受（不为省存储选高风险方案）；用配额/指标与冷数据策略管控；未来在隐私评审后重新评估 |
| R2 | `audience` 级别允许 URL 转发（换取 CDN 命中率） | 受众外泄露在 TTL 内可行 | 短 TTL、`aud_scope` 校验、边缘限速、异常检测、可升级为 `private` |
| R3 | 密文域保留跨用户共享（沿现状） | 确定性加密下的可链接性与确认攻击（ADR-0060 已接受） | 不新增暴露面；摘要不外泄；门槛策略；未来可用 DEFERRED-10 增强 |
| R4 | E2EE 视频体验受"发送端生成"限制 | 无法做到服务端转码级的多档位/秒开 | 发送端预生成 poster/preview/档位；产品接受端侧成本（DEFERRED-7） |
| R5 | 5 阶段迁移跨度大，中途状态复杂 | 长期双读/双路径的维护成本与"忘记加引用"的漏 | 每阶段出口条件 + 对账工具 + 回退演练（§7.3）；引用计数可重算 |
| R6 | `SCANNING` 保留但依赖"必须有生产者" | 若实现时忘了超时兜底，会重现现状滞留问题 | 冻结条款要求"生产者 + 超时 + 存量清理"三件套；Phase 4 必须写用例 |
| R7 | 授权实时复核依赖 Matrix/Moments 可用性 | 依赖不可用时 fail-closed 会拒绝合法请求（可用性体验下降） | 极短授权缓存 + 明确的 5xx 语义与重试指引；不降级为允许 |
| R8 | TTL/门槛/配额数值未定 | Phase 4 若"先写死数字"会与冻结冲突 | 冻结明确"策略冻结、数值配置化"，实现必须留配置位 |
| R9 | 冻结文档与实际实现漂移 | 后续阶段各自解释 | §9.3 启动检查单 + 变更必须新 ADR 覆盖 |
| R10 | 现状的单点（字节与 DB 同机同盘、无备份脚本、无边缘限流）在 Phase 4 之前依然存在 | 故障/滥用风险持续 | 明确不在本冻结范围（DEFERRED-12）；在 Phase 4 计划中作为运维前置项列出 |

### 10.5 Phase 4 可以实现范围（摘要）

Gateway 骨架与新表（expand-only）→ 业务域（Moments）新写入路径与明文域**本用户内**内容寻址 →
引用系统与计数对账 → 删除/生命周期/GC（含存量 `SCANNING` 清理）→ 授权与 Signed URL（服务端 TTL、
subject 绑定、分级转发）→ Variant 模型与 Resolver（E2EE 变体由发送端登记）→ Matrix 只读适配与惰性索引 →
独立 Upload Engine（分片/续传/校验/commit）→ 指标与审计口径 → CDN 前置准备（不含厂商选型与边缘配置）。
**完整 13 条见 §9.1。**

### 10.6 Phase 4 禁止范围（摘要）

改 Matrix Server/协议/E2EE/上传接口/Moments·Avatar API 语义；破坏性 schema 变更；搬移或重加密旧字节；
把明文摘要交给服务器用于 E2EE 去重；明文域跨用户去重与全球去重；服务端处理 E2EE 内容；
Avatar 迁入平台；`private` 级别允许转发或进共享缓存；客户端决定 TTL；提供摘要存在性查询；
E2EE 域引入 `SCANNING`；无 pin/dry-run/审计的 GC；未测量即分片全局锁；删除既有缓存；绕过隔离与摘要墓碑。
**完整 15 条见 §9.2。**

---

## 结语（本阶段边界声明）

- 本文档是 **Freeze Only**：未实现 Media Gateway / Media Object Server / Upload Engine / CDN / 远端去重；
  未修改 Matrix Server、Matrix 协议、E2EE、Megolm/Olm、媒体上传接口、Moments API、Avatar API、
  数据库 schema、客户端缓存代码或 Flutter 业务代码；**本阶段唯一产物是本文档**。
- 冻结的权威顺序：**ADR-001 → ADR-002 → ADR-003 → ADR-004 → ADR-005 → ADR-006**；
  横切原则 P1–P10、安全不变量 I1–I10、性能约束 PF1–PF6 与之同级。
- 任何对本冻结的偏离都必须以**新的 ADR** 覆盖，并在其中说明被替代的条款与迁移影响。
