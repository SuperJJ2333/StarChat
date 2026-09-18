# ChatFlow Media Engine Production Readiness Report

- **验证对象**：Media Engine Phase 0–4 全链路（客户端本地索引 + 服务端 Media Platform）
- **日期**：2026-09-18（Asia/Hong_Kong）
- **仓库**：`SuperJJ2333/StarChat`，分支 `main`，起点 `61b29917`
- **验证依据（先读取的设计约束）**：
  [Phase 3.1 冻结](../architecture/media-engine-phase3-freeze.md)（ADR-001…ADR-006）、
  [Phase 3 设计](../architecture/media-engine-phase3-server-design.md)、
  [Phase 4 实施报告](media-engine-phase4-implementation.md)
- **本阶段定位**：**验证**，不是开发。默认不改代码；仅在发现安全漏洞 / 数据损坏风险 / 生命周期错误 /
  权限绕过时修复。本次共发现并修复 **2 个 High**，记录 **3 个 Medium**（见 §10）。
- **验证环境**：CPython 3.12、SQLite（in-memory，单连接）、本地文件系统、Windows 工作站、
  单进程、无 PostgreSQL / 无 HTTP 服务器 / 无网络 / 无并发负载。
  **所有性能数字均为该环境实测**，不是生产容量结论（§7）。

---

## 1. Executive Summary

| 项目 | 结论 |
| --- | --- |
| ADR-001 Isolation | ✅ **PASS**（明文域无跨用户共享；密文域受确定性信封 + 门槛约束；无 global plaintext dedup，且开启该策略会直接抛错） |
| ADR-002 Digest | ✅ **PASS**（三种 digest_kind 隔离；跨类比较抛异常；无客户端摘要查询；摘要值不出现在任何 API 响应） |
| ADR-003 Authorization | ⚠️ **PASS（修复后）** —— 发现并修复 1 个 High：audience 交付未复核受众，非成员与匿名调用者可读取；现已按"可校验才签发 + 每次交付实时复核"实现 fail-closed |
| ADR-004 Matrix Compatibility | ✅ **PASS**（Matrix 适配器无写路径；解析不产生任何平台行；不搬移/重命名字节；旧媒体只读可用） |
| ADR-005 Upload Boundary | ✅ **PASS**（上传引擎与消息/对象解耦；commit 前不发布 media_id；resume 状态 owner 隔离） |
| ADR-006 Lifecycle | ⚠️ **PASS（修复后）** —— 发现并修复 1 个 High：GC 未保护"变体仍在处理中"的对象；现已加入处理中守卫 |
| Security-001 越权读取 | ✅ PASS（B 读 A 私有媒体 403/404，且不回显 media_id；转发私有 URL 404；B 不能为 A 的对象签发） |
| Security-002 URL 篡改/重放 | ✅ PASS（改 subject/expire/media/variant 或不重签 → 全部失败；客户端无 TTL 入参） |
| Security-003 过期 token | ✅ PASS（统一 404，不泄露存在性/过期/篡改差异） |
| Security-004 Grant 撤销 | ✅ PASS（撤销即递增版本，已签发 URL 与直读同时失效） |
| Security-005 受众边界 | ✅ PASS（**修复后**：成员可读；非成员 404；匿名 404；失去成员资格立即 404；不可校验受众拒绝签发） |
| 数据一致性 Test Data-001/002/003 | ✅ PASS（含引用计数漂移可重算、GC 四类保护、崩溃双向恢复） |
| 并发 Concurrent-001…004 | ✅ PASS（密文并发单 blob、引用幂等、GC 与读并行、删除/引用竞争最终一致） |
| Migration 验证 | ✅ PASS（Matrix `mxc://` 与 Moments 旧能力 URL 均可读且不产生平台对象；新上传走平台；新旧并存） |
| OpenAPI / Contract | ✅ PASS（新增 reconcile 路由后重新导出，`--check` PASS） |
| 自动化门禁 | ✅ PASS（flutter analyze/test、pytest tests/mobile、npm test、scripts/verify.ps1 —— 见 §9） |

### 判定

```
Media Engine Production Candidate: PASS
```

**但附一条强制条件**：修复后的 audience 规则**比 Phase 3.1 冻结文档更严格**，
冻结文档（ADR-003 §4.3.3）应作为一次 ADR 修订记录下来（§10 R1）。
在修订完成前，实现与冻结文档在"audience 可否转发"这一点上**不一致**——实现是收紧方向（更安全），
但按仓库的 ADR 变更纪律，必须补齐记录。

**证据边界（不接受"测试通过所以安全"）**：本次验证覆盖
① 代码级结构断言（类型不可比较、适配器无写路径、路由不直连存储）；
② 行为级用例（越权/篡改/过期/撤销/受众/一致性/并发）；
③ 真实测量（性能与规模）。**未覆盖**：真实 PostgreSQL 并发、多 worker 竞争、真机、CDN、
外部攻击者视角、E2EE 协议层（Megolm/Olm）与该平台的交互（平台不参与，故不在本次范围）。

---

## 2. ADR Compliance

验证套件：`tests/business_api/media_platform_readiness/test_adr_compliance.py`（**24 条，全部通过**）。
每条既断言行为，也断言结构（防"以后重构把规则悄悄去掉"）。

### ADR-001 Isolation — **PASS**

| 冻结要求 | 验证方式 | 结果 |
| --- | --- | --- |
| 明文域不跨用户共享 | 两个用户上传相同字节 → 断言 2 个 blob、作用域恰为 `user:user-a` / `user:user-b` | PASS |
| 禁止 global plaintext dedup | `allow_cross_user_plaintext_dedup() is False`；把策略开关设 `True` 时 `decide()` 抛 `IsolationViolation`（不是静默生效） | PASS |
| 密文域受限复用 | 同密文（确定性信封、>256 KiB）跨用户 → 同一 object/blob；随机信封 → 不同；小于门槛 → 不同 | PASS |
| 隔离地址写进键 | `media/{user,e2ee,public}/<scope-hash>/…`；`key_belongs_to_domain` 对错误域返回 False；`assert_object_domain` 对错配抛异常 | PASS |
| 检索证据 | 搜索 `dedup` / `digest` / `scope` / `namespace`：唯一命中跨用户语义的地方是 `policy.MediaDedupPolicy`（拒绝）与 `repository._find_blob`（按域过滤） | PASS |

### ADR-002 Digest — **PASS**

| 冻结要求 | 验证方式 | 结果 |
| --- | --- | --- |
| 三种 `digest_kind` 存在且语义分离 | 枚举断言 `plaintext_digest` / `ciphertext_digest` / `transport_digest` | PASS |
| **禁止明文=密文比较** | 同字节的明文/密文摘要 `==` → 抛 `CrossKindDigestComparison`；版本不同同样抛 | PASS |
| 无明文摘要进入 E2EE 域 | E2EE ingest 后断言 `digest_kind == ciphertext_digest`，且全库不存在 `isolation_domain='e2ee' AND digest_kind='plaintext_digest'` 的行 | PASS |
| 客户端摘要不可信 | 传输摘要只做校验（不匹配 409）；客户端提交 `plaintext_digest` 作 claim → 422；`transport_digest` 作身份 → 422 | PASS |
| 无客户端摘要查询（存在性预言机） | 遍历 OpenAPI：媒体路由路径/参数中不存在摘要*值*参数（`digest_kind` 是选择器，已单独断言其语义）；源码无 `content_sha256` | PASS |
| 摘要值不外泄 | 采集 ingest / metadata / signed-url 三个响应体，断言不含实际摘要值与 `content_digest` 字段 | PASS |

> 说明：`ciphertext_digest` 与 `plaintext_digest` 的**值**由同一 SHA-256 函数产生，因此数值可以相等；
> 分离它们的是 `kind`（身份的一部分）。这正是 ADR-002 把 kind 纳入身份的原因，测试按此断言。

### ADR-003 Authorization — **PASS（修复后）**

| 冻结要求 | 验证方式 | 结果 |
| --- | --- | --- |
| 所有读取经 Authorization → Resolver → Signed URL | 结构断言：路由模块**不**出现 `MediaRepository`/`LocalBlobBackend`/`read_bytes`/`storage_key`；网关必须调用注入的 authorizer | PASS |
| 只有 authorization.py 能"放行" | 断言 `authorization.py` 之外任何模块都不得构造 `ALLOWED` 结论（适配器只能构造 `DELEGATED`） | PASS |
| private subject binding | 同 token：caller=subject → 通过；caller=他人 → 失败；caller=None → 失败 | PASS |
| TTL 服务端唯一决定 | `mint` 签名只有服务端 `ttl_seconds`；API 模型无 `expires_in`/`ttl` 字段；API 传 `expires_in` → 422 | PASS |
| revoke 生效 | 撤销后：直读 403、已签发 URL 404、`grant_version` 递增 | PASS |
| audience 复核 | 见 §4（修复项 High-1） | PASS（修复后） |

### ADR-004 Matrix Compatibility — **PASS**

| 冻结要求 | 验证方式 | 结果 |
| --- | --- | --- |
| 不修改 Matrix 字节 / 不迁移 | AST 扫描 `MatrixMediaGateway` 类：不出现 `put/delete/write_bytes/unlink/store/ingest`；全模块无 `shutil.move`/`os.rename`/`os.replace`/`shutil.copy` | PASS |
| 不强迁移历史 `mxc://` | 解析 `mxc://…` → `delivery=matrix_token`、`delegated_to=matrix`、`requires_matrix_token=true`，且事后 `MediaObject`/`MediaBlob` 计数为 **0** | PASS |
| 不双写旧媒体 | 旧业务能力 URL 解析为 `read_old_only=true` / `delivery=legacy_capability`，同样零平台行 | PASS |
| 本次改动范围 | 提交范围仅 `services/business-api/app/modules/media/**`、`app/api/media_platform.py`、`app/main.py`、`app/core/config.py`、迁移、测试；未触碰 `third_party/**`、Matrix 协议、E2EE | PASS |

### ADR-005 Upload Boundary — **PASS**

| 冻结要求 | 验证方式 | 结果 |
| --- | --- | --- |
| 与消息发送/媒体对象解耦 | `upload_engine.py` 源码不含 `moments` / `matrix` / `reference` / `media_objects` 依赖 | PASS |
| commit 前不泄漏 media_id | 建会话后 `media_id is None`；`complete` 返回 501 且无 media_id；事后无对象被创建 | PASS |
| resume 状态安全 | 所有者可读会话，其他用户 404 | PASS |

### ADR-006 Lifecycle — **PASS（修复后）**

| 冻结要求 | 验证方式 | 结果 |
| --- | --- | --- |
| 删除=解引用 → ORPHAN → GC | 两条引用释放其一：对象 ACTIVE 且另一引用在；释放其二：ORPHAN 且未删除；再次 attach 可复活 | PASS |
| 状态机合法流转 | `ACTIVE→ORPHAN` 允许；`ACTIVE→DELETED`、`DELETED→ACTIVE` 抛 409 | PASS |
| active media 不被删除 | 见 §5 Data-002 | PASS（修复后含"处理中变体"守卫） |
| pin 生效 | `pin_object` 后 GC 跳过（reason=`pinned`） | PASS |
| upload 中文件保护 | 存在非终态上传会话时 GC 跳过（reason=`active_upload`） | PASS |

---

## 3. Security Audit

套件：`tests/business_api/media_platform_readiness/test_security_readiness.py`（**8 条，全部通过**）。

| 用例 | 场景 | 结果 | 关键断言 |
| --- | --- | --- | --- |
| **Security-001** 越权读取 | A 私有对象；B 尝试读字节、读 metadata、用 A 的 URL、为 A 的对象签发 | PASS | 403/404；响应体不含 `media_id`；转发 URL 404；签发 403 |
| **Security-002** URL 重放/篡改 | 修改 `subject`/`expire`/`media_id`/`variant`（不重签）→ 拒绝；用合法签名换 subject → 另一 caller 仍被拒；直接改签名尾部 → 404 | PASS | 四类字段篡改全部失败；`compare_digest` 校验覆盖全部 claims |
| **Security-002b** 客户端改 TTL | API 传 `expires_in`；检查签发结果 | PASS | 422（未知字段）；`ttl_seconds ≤ 策略值`；`exp` 与服务器时钟一致（±5s） |
| **Security-003** 过期 token | 用过去时钟签发 30s TTL 令牌后访问 | PASS | 404，`MEDIA_SIGNED_URL_INVALID`，响应不含 "expired"/对象 id |
| **Security-004** Grant 撤销 | 建 grant → 签发 → 读成功 → 撤销 → 再读 | PASS | 撤销后 URL 404、直读 403、`grant_version` +1 |
| **Security-005** 受众边界 | 朋友圈受众：作者+好友 B 在受众；C 非好友 | **修复后 PASS** | 成员 200；非成员 404；匿名 404 |
| **Security-005b** 成员资格变化 | 读成功后删除好友关系，再读同一 URL | **修复后 PASS** | 立即 404（实时复核，不依赖签发时快照） |
| **Security-005c** 不可校验受众 | 用 `room:!room:test` 签发 audience 链接 | **修复后 PASS** | 422 `MEDIA_AUDIENCE_UNVERIFIABLE`（宁可不发，不发不可校验的） |

---

## 4. Authorization Audit

### 4.1 读取链路（实测路径）

```
Client ──Authorization header──▶ 路由(签名/subject 校验)
                                   │
                                   ├─ private : codec.verify(subject == caller)
                                   ├─ audience: audience.verify(moment:<id>, caller)  ← 修复项
                                   └─ public  : 无主体绑定
                                   ▼
                          Media Resolver（对象状态/隔离域）
                                   ▼
                          Variant Resolver（ready-only + 授权范围过滤）
                                   ▼
                          Signed URL / 字节交付
```

### 4.2 发现 High-1（已修复）：audience 交付不校验成员

- **现象**：非受众成员（甚至匿名调用者）持 audience URL 可成功读取（实测 200）。
- **根因**：Phase 4 按 ADR-003 §4.3.3 的"受众内可转发"实现了"签发即可读"，
  但**交付时没有复核**；而 ADR-003 的取舍前提是"URL 只在受众内流转"，
  实现把这个前提变成了"任何持有者都能读"。
- **修复**（`app/modules/media/audience.py` + `service.py` + `main.py`）：
  1. **签发门槛**：tier=audience 时，受众引用必须**可校验**（当前仅 `moment:<id>`），
     否则 422 `MEDIA_AUDIENCE_UNVERIFIABLE` —— 房间受众由 Matrix 自身的鉴权媒体端点负责
     （ADR-004 已把聊天媒体交给 Matrix），平台不再签发它无法复核的链接。
  2. **交付复核**：每次交付都用实时 Moments 可见性策略复核成员资格；
     无身份 / 非成员 → 统一 404；可见性收缩（取消好友、拉黑、删除动态、历史范围收窄）立即生效。
  3. **失败即拒绝**：策略查询异常 → 拒绝（fail-closed）。
- **回归**：`tests/business_api/media_platform/test_media_authorization.py` 中两条原用例已按新规则更新
  （原用例编码的是旧的宽松行为）：受众成员可读 + 失去成员资格立即失效 + 不可校验受众拒绝签发。

### 4.3 其余授权结论

| 项 | 结论 |
| --- | --- |
| owner 短路 | 允许（OWNER 规则），不做多余查询 |
| 显式 user grant | 允许，且档位须落在 `variant_scope` 内，否则 403 |
| 无授权 | 403（直读）/ 404（签名交付，避免存在性泄露） |
| 提权尝试 | 通过"申请更高档位"提权无效：授权范围在选档之后过滤，只收窄不放宽（Phase 4 用例 + 本阶段 ADR-003 断言） |
| 管理动作 | 只有 owner 能签发/撤销 grant、pin、attach/release 引用（跨用户尝试 403） |

---

## 5. Data Consistency

套件：`tests/business_api/media_platform_readiness/test_data_consistency.py`（**13 条，全部通过**）。

### Data-001 引用一致性 — PASS

- 建 MediaObject + 引用 A + 引用 B → 释放 A：对象仍 `ACTIVE`、B 仍在、**字节仍在**；
- 释放 B：对象进入 `ORPHAN`（`ref_count=0`、`unreferenced_at` 非空），**仍未删除**，且可被重新 attach 复活为 `ACTIVE`；
- 引用计数缓存被人为改成 99 后，`recount()` 从引用表重算回真实值（3）—— 计数列是可重建缓存，不是真相源。

### Data-002 GC 安全 — PASS（含修复项 High-2）

同时构造 5 类对象后执行 enforce GC：

| 对象状态 | GC 决策 | 断言 |
| --- | --- | --- |
| 有 active 引用 | skip `has_references` | 未删除 |
| 已 pin（`pinned_until` 未来） | skip `pinned` | 未删除 |
| 存在非终态上传会话 | skip `active_upload` | 未删除 |
| **变体处于 `processing`** | skip `variant_processing` | 未删除（**修复项**，见 §10 High-2/R2） |
| 无引用、过宽限期 | collect | 标记 `DELETING` → 删除字节 → `DELETED` |

另外：`dry_run` 只报告不改变任何状态（对象状态与文件存在性均不变）。

### Data-003 崩溃恢复（双向）— PASS

| 方向 | 构造 | 修复动作 | 断言 |
| --- | --- | --- | --- |
| **对象写入完成、索引失败** | 直接在平台命名空间写入一个没有 blob 行的文件 | `MediaReconciler` 按**路径中的隔离段**决定摘要种类（`media/e2ee/**` → ciphertext，其余 → plaintext）并重建 blob 行（`object_id=None`，可再挂载） | dry-run 只报告；enforce 后行存在、`size` 正确、`digest_kind` 正确、E2EE 孤文件**不会**被误标为明文 |
| **索引存在、对象丢失** | 删除 blob 对应文件 | 失效该行（`DELETED` + `deleted_at`），释放摘要槽 | enforce 后状态为 `DELETED`；同一内容可再次入库并得到新 blob |
| 边界 | 旧 `moments/<actor>/…` 文件 | 不在平台命名空间内 | 不重建、不删除、不动（`rebuilt=0`，文件仍在） |

新端点 `POST /api/v1/media/platform/reconcile`（维护令牌门控，**默认 dry_run**）暴露该能力。

---

## 6. Migration Validation

| 项 | 方式 | 结果 |
| --- | --- | --- |
| Matrix 旧媒体（`mxc://`）可读 | 解析断言 + 零平台行 | PASS（读取仍由 Matrix 承担，平台不改字节、不重加密） |
| Moments 旧媒体（旧能力 URL）可读 | `read_old_only=true`；另在集成用例中用"旧式上传行 + 真实文件"读回原始字节 | PASS |
| 新上传走平台 | `POST /media/platform/objects` 与 `POST /media/platform/moments/attachments` 端到端；后者经**未修改的** `POST /moments` 发布、经**未修改的** `/moments/media/content/{token}` 读回 | PASS |
| 新旧并存 | 平台对象与旧 `moment_media_uploads` 记账行指向同一份字节（一份字节、两条读取路径） | PASS |
| 迁移可回退 | 迁移 `0069` 仅 `create_table`/`create_index`（含部分唯一索引），`downgrade` 仅删本次新增对象；`alembic upgrade head --sql` 在门禁中通过（链路含 `0068 → 0069`） | PASS |
| 未修改既有表/列 | 迁移无 `alter`/`drop`；两个把 head 钉死的基线用例已按 expand-migrate 流程更新为 `0069` | PASS |

---

## 7. Performance Benchmark

**环境**：CPython 3.12 / SQLite in-memory / 本地磁盘 / 单进程 / Windows 工作站（非生产）。
**方法**：`tests/business_api/media_platform_readiness/test_benchmarks.py`，每项 N 次调用取真实耗时百分位。
**未做**：真实压测（HTTP 服务、PostgreSQL、并发、网络、CDN）→ 一律标注 **NOT MEASURED**，
绝不以本机单进程数字冒充容量结论。

| Benchmark | 场景 | n | p50 | p95 | p99 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| **001** | Media resolve（网关 resolve → 对象 + 变体清单） | 1000 | **0.44 ms** | 0.78 ms | 1.57 ms | 200 个对象轮询 |
| **002a** | Authorization（owner 短路） | 1000 | **0.005 ms** | 0.005 ms | 0.008 ms | 纯内存判定 |
| **002b** | Signed URL 签发（HMAC） | 1000 | **0.012 ms** | 0.017 ms | 0.050 ms | 服务端 TTL |
| **002c** | Signed URL 校验（含 HMAC 比对） | 1000 | **0.013 ms** | 0.017 ms | 0.057 ms | 篡改/过期同路径 |
| **002d** | Authorization（grant 路径，含一次索引查询） | 500 | **0.36 ms** | 1.19 ms | 3.69 ms | 比 owner 路径贵 ~2 个数量级，仍是亚毫秒级 |
| **003** | Variant resolver（图片/视频 × 网络 × 偏好，含 allow-list） | 500×10 组 | **0.22–0.34 ms** | ≤0.80 ms | ≤1.51 ms | 选档结果同时断言正确性 |
| **004** | GC（1,000 对象 + **10,000 引用**） | 1 | **280 ms**（整轮） | — | — | 全部正确跳过（`has_references=1000`），0 误删；插入 10k 引用 139 ms |

**规模模拟**（`test_scale_simulation.py`，同环境）：

| Scenario | 目标 | 实测 | 结论 |
| --- | --- | --- | --- |
| 001 | 1000 用户 × 1000 引用 = **1,000,000** 行 | **1,000,000 行写入 28.1 s**；单用户查询 = 1000；单对象活跃引用计数查询 **0.37 ms**；GC dry-run（200 对象上限）**127 ms** | 达到目标规模；查询走索引，GC 与表大小解耦（受 `limit` 约束） |
| 002 | 热门朋友圈 10,000 次授权 | **10,000 次 / 9.35 s ≈ 0.94 ms 每次**，全部允许；非成员 200 次全部拒绝 | 复核式受众校验在热点规模下仍为亚毫秒级 |
| 003 | 大量孤儿 + GC | **2,000 个孤儿 8.8 s 回收**（1.34 MB），50 个活跃对象全部正确跳过；第二轮 **12.9 ms 无操作** | 回收稳定、可重复、不误删 |

**性能结论**：单进程元数据路径（resolve / 授权 / 签发 / 选档）在**亚毫秒到毫秒级**，
GC 与查询随 `limit`/索引而非表规模增长。**未测**：真实并发（多 worker 争用）、PostgreSQL 计划、
网络与 CDN、以及 Phase 4 已记录的两项结构性瓶颈（媒体写路径的全局串行锁、
上传仍受 50 MiB 上限约束）。这些属 **NOT MEASURED**，不得据此宣称生产容量。

---

## 8. Concurrency Validation

| 用例 | 场景 | 结果 | 断言 |
| --- | --- | --- | --- |
| **Concurrent-001** | 同一密文（确定性信封）4 次上传，跨 3 个用户 | PASS | 只有 **1 个 blob / 1 个 object**（部分唯一索引 + 对象复用） |
| **Concurrent-001b** | 同一明文 2 个用户上传 | PASS | 2 个 blob、作用域各自独立（**不**因并发而跨用户合并） |
| **Concurrent-002** | 同一 (media, business_type, business_id) 创建 5 次 | PASS | 1 条引用行、1 个 reference_id、`ref_count=1`（幂等） |
| **Concurrent-003** | 对象被引用时执行 enforce GC，随后读取 | PASS | GC 不收集该对象；读取 200 |
| **Concurrent-004** | 删除引用与新增引用竞争 | PASS | 释放→`ORPHAN`→晚到的 attach 复活为 `ACTIVE`；若已真正回收，再 attach 会 **404/拒绝**（不会产生指向不存在字节的引用） |

**并发验证的诚实边界**：以上在**单进程、SQLite 单连接**下验证的是**语义正确性**
（唯一约束、幂等、状态收敛），**不是**多进程竞争压力测试。真正的多 worker 竞争
（PostgreSQL + 2 个 API worker）**NOT MEASURED**——需在预生产环境按 §11 的建议补测。

---

## 9. Automation Gate

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| Flutter 静态分析 | `flutter analyze`（`apps/mobile_flutter`） | ✅ No issues found（28.3s） |
| Flutter 全量测试 | `flutter test --timeout 120s --concurrency=2` | ✅ **3143 passed / 0 failed**（退出码 0；JSON 复核 `testDone(hidden=false)=3143`） |
| 边界测试（仓库门禁子集） | `py -3.12 -m pytest tests/mobile -q` | ✅ 70 passed（579.78s） |
| HTML demo | `npm test`（`frontend/`） | ✅ 209 passed / 0 failed |
| 仓库整体门禁 | `pwsh -NoProfile -File scripts/verify.ps1` | ✅ `Verification: PASS`（退出码 0） |
| OpenAPI 一致性 | `py -3.12 scripts/export_openapi.py --check` | ✅ PASS（新增 reconcile 路由后重新导出，零漂移） |
| 本次验证套件 | `py -3.12 -m pytest tests/business_api/media_platform_readiness -q` | ✅ **52 collected / 52 passed**（ADR 24 + 安全 8 + 一致性·并发 13 + 基准 4 + 规模 3） |
| Phase 4 既有套件（含被收紧规则更新的 2 条） | `py -3.12 -m pytest tests/business_api/media_platform -q` | ✅ **72 collected / 72 passed** |

**Flutter 全量测试的抖动记录（如实）**：默认并发下连跑两次，各出现 **1 条不同的既有实时定时器/调度用例**失败
（第一次 `features/contacts/request_friend_page_test.dart` + `features/matrix/account_client_selection_test.dart`，
第二次 `features/matrix/call_connected_fallback_test.dart` 的"10 秒超时"用例）；
两者**单独运行均通过**，降到 `--concurrency=2` 后全量 **3143/3143 通过**。本阶段未改动任何 Flutter 代码，
且该工作树同时被另一个会话改动（见下方计数口径说明），故判定为既有用例在并行负载/并发编辑下的抖动，
不作为本次变更的回归证据。

**计数口径说明（避免误读历史数字）**：本次以 JSON reporter 精确测得 **3143** 条非隐藏用例，
并以 `--concurrency=2` 全量复跑确认。Phase 2/4 记录的 `3120` 与本次相差 23 条，原因是
**同一工作树上另有一个并发会话正在改动 Flutter 代码与测试**（其新增的
`test/features/auth/auth_bug_0917_test.dart`、`test/features/matrix/room_opening_policy_test.dart`、
`test/features/ledger/ledger_presentation_test.dart` 等文件在 `git status` 中为未跟踪/已修改，
且 `docs/workflow/tasks/2026-09-18-chatflow-bug-01-10.md` 同时存在）——
因此本次 Flutter 门禁是在**被并发修改的树**上取得的，数字只能视为指示性证据。
本报告与该并发批次**互不包含**：本阶段的提交只包含 `services/business-api/**`、
`tests/business_api/**`、`packages/api-contracts/**` 与本报告相关文档，未提交任何 Flutter 文件。

**OpenAPI 检查项**：文档一致（重新导出后零漂移）、schema 一致（路由参数/请求体由同一 FastAPI 应用生成）、
无遗漏（媒体平台 **20 条路由**全部在册，含 `content/{token}`、`reconcile`、`gc`、`metrics`、`uploads*`、`grants*`、`references*`）。

---

## 10. Known Risks

### 已修复（本次）

| # | 等级 | 问题 | 文件位置 | 修复 |
| --- | --- | --- | --- | --- |
| **High-1** | High（权限绕过） | audience 交付不复核受众：非成员/匿名可读 | `app/modules/media/service.py`、**新增** `app/modules/media/audience.py`、`app/main.py` | 可校验才签发（`MEDIA_AUDIENCE_UNVERIFIABLE`）+ 交付时实时复核（fail-closed）+ 成员资格变化立即生效 |
| **High-2** | High（生命周期错误） | GC 未保护"变体仍在 `pending/processing`"的对象，可能回收正在产出变体的字节 | `app/modules/media/lifecycle.py`、`domain.py`（新增 `GcSkipReason.VARIANT_PROCESSING`） | GC 增加处理中变体守卫；新增对应用例 |
| **Bug-1** | Medium（可观测性） | 新增 reconciles 指标未注册，触发计数器时抛 `KeyError` | `app/modules/media/metrics.py` | 注册 `reconcile_rebuilt` / `reconcile_invalidated` |

### 记录未修复（本阶段禁止新增功能，且不构成数据/安全风险）

| # | 等级 | 问题 | 文件位置 | 建议 |
| --- | --- | --- | --- | --- |
| **M1** | Medium（隐私/工程） | ingest 端点允许调用方自选 `digest_kind`，即自选隔离域；把密文标为 `plaintext_digest` 只会进入按用户隔离域（更保守、无泄露），但语义上不该由客户端决定 | `app/api/media_platform.py::ingest_object` | 按 `origin_domain` 固定 digest 家族（`chat` ⇒ 仅 ciphertext），或仅允许服务/适配器调用该端点 |
| **M2** | Medium（体验/接口语义） | Variant Resolver 无"用途"维度：只要 poster 就绪，`prefer=quality`+WiFi 仍返回 poster（选档只能在 `allowed_kinds` 白名单内重排） | `app/modules/media/variants.py`、`policy.variant_preference_order` | 增加 `purpose ∈ {list, playback}`；播放路径传 `allowed_kinds={档位集合}`（现有读取路径已如此使用） |
| **M3** | Medium（成本/运维） | 重建的 unattached blob（`object_id IS NULL`）不在对象级 GC 视野内，长期会积累 | `app/modules/media/reconcile.py`、`lifecycle.py` | 增加 blob 级 GC 规则：无 `object_id`、超期、无变体引用 → 回收；并在对账报告中给出计数 |
| **R1** | 记录（治理） | 实现的 audience 规则**严于** Phase 3.1 冻结的 ADR-003 §4.3.3 | `docs/architecture/media-engine-phase3-freeze.md` | 以一次 ADR 修订记录收紧（可校验才签发 + 交付复核），保持"实现与冻结一致"的纪律 |
| **R2** | 记录（覆盖缺口） | 多进程/多 worker 竞争与 PostgreSQL 计划 **NOT MEASURED** | — | 预生产环境补：2 worker 并发同密文上传、并发引用创建、GC 与读并发 |
| **R3** | 记录（性能） | 媒体写路径的全局串行锁（Phase 3 审计 A10）与 50 MiB 上传上限仍在 | `third_party/synapse/chatflow_media_dedup.py`、`data/synapse/homeserver.yaml` | 按冻结要求"先测量再分片"；上传上限调整属部署变更 |
| **R4** | 记录（范围） | 未做真机、CDN、对象存储、Avatar 接入 | — | 均属冻结中的 DEFERRED，不在本次判定范围 |

---

## 11. Release Recommendation

### 判定

```
Media Engine Production Candidate: PASS
```

**依据**：ADR-001…006 全部 PASS（其中 2 条在修复后 PASS）；无权限绕过；无数据删除风险
（GC 四类保护 + 双向崩溃恢复 + 引用计数可重算）；无 E2EE 破坏（平台不接收明文摘要/密钥、
不解密、不转码、不搬移 Matrix 字节）；Migration 可回退（expand-only + 旧媒体零改动可读）；
GC 安全；OpenAPI 一致；自动化门禁全绿。

### 发布为"生产候选"的强制条件

1. **ADR 修订**：把 audience 收紧规则写入 ADR-003（或新 ADR），消除实现与冻结文档的表述差异（R1）。
2. **预生产并发补测**：2 worker + PostgreSQL 下重跑 Concurrent-001/002/003/004 与 GC（R2）。
3. **配置**：生产必须设置独立的 `BUSINESS_MEDIA_URL_SIGNING_SECRET`（未设置时回退到头像签名密钥，
   会耦合轮换影响面）与 `BUSINESS_MEDIA_MAINTENANCE_TOKEN`（未设置时生产环境对维护端点 503，fail-closed）。
4. **运维**：把 `POST /media/platform/reconcile`（默认 dry_run）纳入巡检，把 `GET /media/platform/metrics`
   接入监控；对 `MEDIA_SIGNED_URL_INVALID` / `authorization_denied` 建立告警。
5. **客户端接入**：新端点尚未被客户端调用（当前用户路径仍全部走旧接口，因此**上线风险低**）；
   接入时需按 `prefer`/`allowed_kinds`/501 特性探测实现选档与上传能力协商。

### 门禁前提（不得省略）

本次 PASS 建立在"**旧用户路径未被改动**"这一事实上：Chat 仍走 Matrix、朋友圈仍走既有 API，
平台是**新增并行路径**（strangler）。因此即使新路径有问题，回退只需停止调用新端点。
反过来，**新路径尚未经真实流量验证**——在客户端接入并灰度之前，不应宣称"生产已验证"。

### 未覆盖声明（拒绝"测试通过所以安全"）

- 未测：真实并发/多 worker、PostgreSQL 执行计划、真机、网络与 CDN、外部攻击者视角、长期运行
  （磁盘增长、索引膨胀、GC 周期）；
- 测试覆盖的是**本次列出的**边界与不变量，不是全部可能输入；
  未覆盖的输入空间（畸形容器、超大 GIF、异常 MIME、恶意变体请求）**未被证明安全**，只被证明"未测"；
- E2EE 协议层（Megolm/Olm 轮换、密钥恢复）与平台无交互，本次未验证，也不应由此报告背书。
