# 2026-09-17 ChatFlow Media Engine Phase 3.1 — Architecture Freeze（冻结架构边界）

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令（本会话）。**冻结架构边界**，为 Phase 4 Implementation 提供稳定架构依据。
  **本阶段只设计，不编码。**
  **禁止修改**：Matrix Server、Matrix 协议、E2EE、Megolm/Olm、媒体上传接口、Moments API、Avatar API、
  数据库 schema、客户端缓存代码、Flutter 业务代码。
  **禁止实现**：Media Gateway、Media Object Server、Upload Engine、CDN、远端去重。
  **本阶段产物只有设计文档**（`docs/architecture/media-engine-phase3-freeze.md`）。
  不做 `git pull`、不构建 APK/IPA、不真机、不部署。
- 关联计划/ADR：本冻结文档自身即 ADR 集（ADR-001…ADR-006）；
  上游 = [Phase 3 审计](../../architecture/media-engine-phase3-server-audit.md)、
  [Phase 3 设计](../../architecture/media-engine-phase3-server-design.md)、
  [ADR-0060](../../adr/0060-content-addressed-media-dedup.md)。
- 当前状态：**冻结文档完成并已交付（未编码、未改业务代码）**；是否提交/推送待用户确认（见"交接与回退"）。
- 负责人、工作树、文件所有权、源码commit：本地工作树 `D:\pythonProject\outsource\StarChat`，
  分支 `main`，基线 `81d9e612`（Phase 3 文档已推送至 `0158697b`）。
  本任务只新增 `docs/architecture/media-engine-phase3-freeze.md` 与本任务记录。
- 最后更新时间（含时区）：2026-09-17（Asia/Hong_Kong）。
- 下一条具体操作、必要输入、阻断的验收ID：Phase 4 启动前需（1）批准本冻结；（2）确认 §8 的 15 项 DEFERRED 不实现；
  （3）明确 Phase 4 第一步 = Phase A（Gateway abstraction，只读）。当前**无阻断项**。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| F1 | 不编码、不修改业务代码 | 只写文档 | 工作树仅新增 2 个 `docs/**` 文件；无 `lib/`、`services/`、`infra/`、`data/` 改动 | 未发布 | — |
| F2 | 明确媒体隔离策略（Option A/B/C 的安全/存储/E2EE/复杂度 + 第一阶段正式方案） | 冻结 | 冻结文档 §4.1（ADR-001）；明文域 = Option A，密文域 = 保留受限共享，**拒绝 Option C** | 未发布 | 需隐私评审后才能重估跨用户明文去重 |
| F3 | 明确 digest 模型（三类摘要：谁算/谁信/谁能访问/用途 + 禁止明文=密文） | 冻结 | §4.2（ADR-002）§4.2.1–§4.2.7 | 未发布 | 门槛数值 DEFERRED-2 |
| F4 | 明确 E2EE 去重边界（不做全球 dedup / 只做用户空间 dedup / 只做密文对象复用） | 冻结 | §4.2.6（明文 hash 风险 / 密文 hash 前提 / 收敛加密风险 + 5 条边界结论） | 未发布 | — |
| F5 | 明确 Object / Blob / Variant 模型与关系 | 冻结 | §4.2.7（三层关系 + 冻结最小字段集 + Variant 规则） | 未发布 | — |
| F6 | 明确 MediaReference 模型与字段 | 冻结 | §4.6.1（`reference_id/media_id/business_type/business_id/permission_scope/created_at` + `state`/`ref_kind` + 6 条规则） | 未发布 | — |
| F7 | 明确权限模型与读取流程 | 冻结 | §4.3.1（Client → Authorization → Media Resolver → Variant Resolver → Signed URL → Download） | 未发布 | — |
| F8 | Signed URL 绑定 media_id/subject/expire/signature；回答"是否允许受众内转发" | 冻结 | §4.3.2（最小绑定集 + 扩展）、§4.3.3（`audience` 允许并声明风险；`private` 禁止，以 subject==调用方身份 实现） | 未发布 | audience 转发为**有意接受**的风险 |
| F9 | TTL 不得由客户端 `expires_in` 决定；写策略不写固定数字 | 冻结 | §4.3.4（相对策略 public ≥ audience ≥ private；poster ≥ image ≥ video ≥ original；服务端唯一决定）；数值 DEFERRED-3 | 未发布 | — |
| F10 | Matrix Media 兼容策略（Adapter + 旧数据永远可读；双写/渐进/lazy/永不迁移四选一） | 冻结 | §4.4.1（永不迁移字节 + 惰性建索引 + 字节不双写 + 双读）、§4.4.2（MatrixMediaGateway / BusinessMediaGateway） | 未发布 | — |
| F11 | Moments / Avatar 接入边界 | 冻结 | §4.4.3（Moments = Phase 1 接入）、§4.4.4（Avatar **延期**，逐条列出 TTL/高刷新/CDN/权限/收益≈0 理由） | 未发布 | Avatar 迁入 = DEFERRED-4 |
| F12 | Video Pipeline 边界（E2EE 视频谁生成） | 冻结 | §4.4.5（**发送端**：original → poster → preview → compressed → encrypt → upload；服务端不可能代劳；接收端生成 DEFERRED-5；明文域服务端转码 DEFERRED-6） | 未发布 | — |
| F13 | Upload Engine 边界（1GB+ 属于 Media Engine 还是独立引擎） | 冻结 | §4.5（**独立子系统** + UploadSession/Chunk/Resume/Checksum/Encrypt/Commit + E2EE 先加密再分片与 CTR 计数器连续性约束） | 未发布 | 上限调整属部署变更 |
| F14 | CDN 模型（URL 签名/缓存控制/权限校验/Variant 选择） | 冻结 | §4.4.6（Storage → Media Gateway → CDN → Client；CDN 不参与授权；三级缓存；选档在 Resolver） | 未发布 | 厂商选型 DEFERRED-12 |
| F15 | 删除与生命周期（删除 ≠ 删 Object；ACTIVE/ORPHAN/DELETING/DELETED） | 冻结 | §4.6.2（Remove Reference → Check → Mark Orphan → GC）、§4.6.3（GC 约束）、§4.6.4（Variant 状态机） | 未发布 | 保留期数值 DEFERRED-9 |
| F16 | `SCANNING` 状态处理（保留并定义生产者，或删除设计） | 冻结 | §4.6.5（保留 + 必须有生产者 + 超时兜底 + 存量清理 + E2EE 域不得引入） | 未发布 | — |
| F17 | 大文件能力（chunk/resume/background/checksum） | 冻结 | §4.5.3（全部在 Phase D 范围，本阶段不实现） | 未发布 | — |
| F18 | 安全审计章节（Threat Model 七项） | 冻结 | §5.1（hash 泄露 / URL 泄露 / 越权 / replay / token 盗用 / reference 污染 / CDN 滥用，各含对策与残余风险）+ §5.2（不变量 I1–I10） | 未发布 | — |
| F19 | 性能目标冻结（图片/Poster/视频/大群） | 冻结 | §6.2（缩略图缓存命中 <100ms、poster <50ms、图片首字节、视频 preview 首字节、拖动、千人群回源 ≤1 次/边缘节点、万人回源 ≤5%）+ §6.3 约束 PF1–PF6 | 未发布 | 千人/万人**从未验收**，须分档验收 |
| F20 | 迁移路线冻结（Phase A–E） | 冻结 | §7.1（Gateway abstraction → Reference system → Variant resolver → Upload engine → Remote optimization）+ §7.2 逐阶段回退 + §7.3 验收证据 | 未发布 | — |
| F21 | 输出格式符合任务书 §22 的 9 节结构 | 冻结 | 文档 §1–§9 与任务书结构一一对应；ADR-001…ADR-005 为任务书要求的五条，另增设同级 ADR-006 承载删除/状态机 | 未发布 | — |
| F22 | 必须输出 "ChatFlow Media Engine Phase 3.1 Architecture Freeze Report"（已冻结/未冻结/风险/可实现/禁止） | 冻结 | 文档 §10（10.1 已冻结 · 10.2 D-01…D-15 对照 · 10.3 未冻结 · 10.4 风险 R1–R10 · 10.5 可实现 · 10.6 禁止） | 未发布 | — |
| F23 | 不得声称"设计完成" | 文档声明 | 全文无"设计完成"字样（已检索 = 0 命中）；顶部为 Freeze Only 声明 | 未发布 | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 文档（本阶段唯一产物） | 无构建 | `0158697b`（Phase 3 文档）+ 本阶段文档 | 无 | `docs/architecture/media-engine-phase3-freeze.md` | 无（未部署；冻结阶段） |

- 命令与退出码：本阶段**未运行** Flutter/仓库门禁（无代码、配置或 schema 变更；按仓库规则，
  纯文档改动只需链接/一致性检查）。
  - 执行的检查：标题结构核对（§1–§9 + §10 Report）、D-01…D-15 覆盖度检索（各 4–9 处命中）、
    ADR 编号一致性检索（ADR-001…006，未误伤 ADR-0060）、禁用措辞检索（"设计完成" 0 命中）。
  - 最后代码门禁 = Phase 2（`flutter analyze` 0 issue；全量 **3120 通过**；`verify_ui_contract` PASS；
    `pytest tests/mobile` 70 通过；`npm test` 209 通过；`scripts/verify.ps1` `Verification: PASS`），
    此后工作树未再变更代码。
- 未执行项：真机、构建、部署（本阶段性质所限）。
- 复用依据：Phase 3 推送后工作树干净；本阶段仅新增文档，未触碰任何门禁输入。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 冻结设计（15 决策 → 6 条 ADR + 安全/性能/迁移/延后/Phase 4 边界） | 2026-09-17 | 2026-09-17 | 主动 | — | `docs/architecture/media-engine-phase3-freeze.md` | 自检 |
| 结构自检与编号对齐（任务书 §22 结构、ADR-001…005 命名、ADR-006 增设说明、D 覆盖度、禁用措辞） | 2026-09-17 | 2026-09-17 | 主动（1 次返工：ADR 由 101–106 改为符合任务书的 001–006，并补 §4.2.6/§4.2.7/§4.6.1 三个自洽小节） | — | 结构检索结果（见"版本与证据"） | 交付/推送确认 |
| 交付（任务记录 + 状态索引；提交与推送待确认） | 2026-09-17 | 2026-09-17 | 主动 | — | 本文件 + `docs/workflow/current-state.md` | — |

总墙钟：同一工作日内完成。返工：1 次（编号体系对齐任务书要求的结构，并把"去重边界结论 / 模型字段集 /
引用模型"从上游设计文档搬进冻结文档，使其可独立引用）。

## 交接与回退

- 已确认根因/已排除假设：
  - 已确认：现状的四域媒体路径与治理缺口（见 Phase 3 审计）；E2EE 链路服务器从不接收明文摘要；
    服务端已有可复用的密文摘要 + 引用骨架；客户端无可续传上传、Synapse 上限 50 MiB。
  - 已排除：**全球去重（Option C）作为第一阶段方案**——它把存储节省建立在存在性/确认攻击面、
    跨租户滥用耦合与"无法承诺单用户彻底清除"之上（用户明确要求"不要为了节省存储直接选择高风险方案"）。
  - 已排除：**Avatar 强行迁入平台**——与 TTL/版本/高频刷新语义冲突且收益≈0（逐条理由见 §4.4.4）。
  - 已排除：服务端处理/转码 E2EE 内容——服务器无明文、无密钥，技术上不可能。
- 待办及验收失败项：无阻断项。Phase 4 启动前需用户批准本冻结 + 确认 §8 的 15 项 DEFERRED 不实现。
- 已发布与仅候选的区别：**仅候选**（本地文档；未构建、未部署）。是否提交/推送待用户确认。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不涉及生产；§7.2 已冻结每阶段回退动作。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：① 冻结文档顶部 Freeze Only 声明是否仍完整（防止被误当作已实现）；
  ② §10.2 的 D-01…D-15 是否全部仍为 FROZEN；③ 任何对 ADR-001…006 的偏离是否走了"新 ADR 覆盖"流程。
