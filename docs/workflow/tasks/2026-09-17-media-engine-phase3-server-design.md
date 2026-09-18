# 2026-09-17 ChatFlow Media Engine Phase 3 — 服务端媒体对象基础设施（设计与审计）

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令（本会话）。**设计未来的服务端媒体对象基础设施**
  （Media Platform：Chat / Moments / Avatar / File 共用的 Media Object / Variant / Reference /
  Permission / Lifecycle / Storage / CDN）。**本阶段只设计，不编码**；不修改业务代码。
  **禁止**：修改 Matrix Server、Matrix 协议、E2EE、媒体上传接口、朋友圈 API、数据库 schema、
  客户端缓存代码；**不实现**全球媒体去重、CDN 改造、服务端对象迁移（属 Phase 3 后半阶段）。
  不 `git pull`、不构建 APK/IPA、不真机、不部署。
  （本轮用户另行授权：完成后把改动分逻辑提交推送到 GitHub `main`。）
- 关联计划/ADR：ADR-0060 [`docs/adr/0060-content-addressed-media-dedup.md`](../../adr/0060-content-addressed-media-dedup.md)（确定性加密 + 密文摘要去重 + 逐用户引用，**本设计不推翻**）；
  Phase 0 [`media-engine-v1.md`](../../architecture/media-engine-v1.md)；
  Phase 2 [`media-engine-phase2-local-index.md`](../../architecture/media-engine-phase2-local-index.md)；
  客户端审计 [`2026-09-17-media-architecture-audit.md`](../../verification/2026-09-17-media-architecture-audit.md)。
- 当前状态：**完成（设计文档 + 只读审计；无代码改动）**。
- 负责人、工作树、文件所有权、源码commit：本地工作树 `D:\pythonProject\outsource\StarChat`，
  分支 `main`，基线 `81d9e612`。本任务只新增两份文档：
  `docs/architecture/media-engine-phase3-server-audit.md`、
  `docs/architecture/media-engine-phase3-server-design.md`；不改任何 `lib/`、`services/`、`infra/`、`data/`。
- 最后更新时间（含时区）：2026-09-17（Asia/Hong_Kong）。
- 下一条具体操作、必要输入、阻断的验收ID：若获批准进入实现 → 按设计 §14 的 **Phase A（Media Gateway，不改变旧流程）** 起步；
  前置输入 = 附录 C 的开放问题（Q1 去重选型、Q3 受众级令牌、Q4 原图权限、Q5 E2EE 视频预生成、Q8 配额数值）决策。
  当前**无阻断项**（本阶段交付物已完成）。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| D1 | 现状审计：Chat/Moments/Avatar/File 各自"存哪/谁管生命周期/谁删除/谁控权限/是否可复用" | 只读审计 | `docs/architecture/media-engine-phase3-server-audit.md` §1–§2（每条附 `path:line`） | 未发布 | — |
| D2 | 核心对象模型：MediaObject（含"明文/密文 hash、谁算、可信性、隐私"讨论） | 设计 | 设计 §4（三层 Object/Blob/Variant + `digest_kind` 5 条强制规则） | 未发布 | — |
| D3 | MediaVariant（图片 Original→Thumbnail→Preview→Compressed；视频 Original→Compressed→Preview→Poster） | 设计 | 设计 §5（变体枚举、族谱 `generation`、失败/跳过状态） | 未发布 | — |
| D4 | MediaReference（业务对象 → 引用 → 媒体；引用计数） | 设计 | 设计 §6（observed/declared 两级 + E2EE 不可数矛盾的保守策略） | 未发布 | — |
| D5 | 加密去重：方案 A/B/C 技术分析 | 设计（**不选型**） | 设计 §7（A/B/C 对照表 + 现状即"方案 B/收敛加密"的形式化 + §7.6 不选型声明） | 未发布 | 需隐私/产品评审 |
| D6 | 权限模型（A 上传、聊天发送、朋友圈发布、B 收到 → 谁能访问） | 设计 | 设计 §8（Grant 模型 + fail-closed 判定顺序 + 变体级授权 + 可见性分级） | 未发布 | — |
| D7 | 删除策略（引用计数 → 归零 → GC；不得"删消息=删文件"） | 设计 | 设计 §9（三段状态机 + 保留期/下限/pin 保护/dry-run） | 未发布 | — |
| D8 | 生命周期 Upload / Read / Delete | 设计 | 设计 §9.1（三条主流程）+ §9.2（6 个实体状态机） | 未发布 | — |
| D9 | 大文件上传（1GB+：分片/续传/校验/重试/后台） | 设计（不实现） | 设计 §10（会话式协议 + 与 E2EE 计数器连续性/去重时机的约束 + 客户端现状对照表） | 未发布 | 需客户端改造 |
| D10 | 视频能力（360/720/1080 转码 + Progressive Loading） | 设计 | 设计 §5.4（转码流水线 + poster→preview→档位→原片；E2EE 域只能端侧生成） | 未发布 | E2EE 下服务端不可能代劳 |
| D11 | CDN（签名 URL/权限/过期/防盗链） | 设计 | 设计 §12（L1/L2/L3 分级 + 能力清单；**不实现**） | 未发布 | 需 CDN 能力确认 |
| D12 | 数据库模型（media_objects/variants/references/access_grants/upload_sessions） | 设计（不创建） | 设计 §13（7 张表 DDL 草案 + 与现状表映射） | 未发布 | 需 migration 评审 |
| D13 | 迁移方案 Phase A→D（不能一次迁移） | 设计 | 设计 §14（四阶段 + 每阶段回退 + 7 条不变量 + 对账工具） | 未发布 | — |
| D14 | 安全审计（hash 泄露/未授权/reference 越权/URL 泄露/CDN abuse/replay/expired token） | 设计 | 设计 §15（逐项「现状→对策→残余风险」） | 未发布 | — |
| D15 | 性能设计（图片秒开/视频快播/千人群/万人并发） | 设计（含实测基线引用） | 设计 §16（实测基线 + 目标 + 容量估算 + 瓶颈 + 指标 + 验收方法） | 未发布 | 千人/万人**从未验收** |
| D16 | 架构图（上传/下载流程） | 设计 | 设计 附录 A（A.1 上传、A.2 下载、A.3 组件边界） | 未发布 | — |
| D17 | 不实现 Phase 4（AI 分析/智能压缩/自动标签/图片搜索/视频理解） | 只列路线图 | 设计 §17 | 未发布 | — |
| D18 | 明确"Architecture Design Only"，不得写"已经实现" | 文档声明 | 设计文档顶部横幅 + 结语；审计文档顶部声明 | 未发布 | — |
| D19 | 本阶段未修改任何业务代码 | 只读 | `git status` 中本任务只新增 2 个 `docs/architecture/media-engine-phase3-*.md` | 未发布 | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 文档（本阶段唯一产物） | 无构建 | `81d9e612` + 本阶段文档 | 无 | `docs/architecture/media-engine-phase3-server-audit.md`、`docs/architecture/media-engine-phase3-server-design.md` | 无（未部署；设计阶段） |

- 命令与退出码（本阶段**不运行** Flutter 测试/构建，因为**未改任何代码**）：
  - 只读检索/读取：`git status --porcelain`、`git remote -v`、源码与文档读取（无写操作）。
  - 未执行：`flutter analyze`、`flutter test`、`scripts/verify.ps1`、`npm test`、`pytest`
    —— 本阶段无代码/配置/schema 变更，按仓库"文档改动只需链接/一致性检查"的规则执行；
    最后一次全量门禁结果见 Phase 2 任务记录（3120 通过 / `Verification: PASS`，工作树未再变更代码）。
- 未执行项：真机、构建、部署、push（push 由本轮用户授权，见"阶段计时"后的交付说明）。
- 复用依据：Phase 2 已完成 `flutter analyze` / 全量 3120 通过 / `verify_ui_contract` PASS /
  `pytest tests/mobile` 70 通过 / `npm test` 209 通过 / `scripts/verify.ps1` PASS；本阶段仅新增文档，
  未触碰上述输入。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 只读现状审计（三条链路、存储/生命周期/权限/可复用性、基础设施、契约与测试） | 2026-09-17 | 2026-09-17 | 主动 | 3 个只读子审计（基础设施+Matrix 媒体 / 客户端链路 / 业务 API 生命周期）与主审计并行 | 审计文档 §0–§8（全部 `path:line`） | 设计 |
| 设计（17 章 + 3 附录） | 2026-09-17 | 2026-09-17 | 主动 | — | 设计文档（Architecture Design Only） | 评审/推送 |
| 文档自检（结构、锚点、与 Phase 0/1/2 及 ADR-0060 的一致性、"不写已实现"声明） | 2026-09-17 | 2026-09-17 | 主动 | — | 标题结构检查、术语与证据交叉核对 | 交付 |
| 提交与推送 | 2026-09-17 | 2026-09-17 | 主动（用户授权） | — | 见"交付与推送" | — |

总墙钟：同一工作日内完成。重复工作：无（本次未返工重写文档）。

## 交付与推送（本轮用户授权）

- 用户本轮明确授权："完成后请你推送到github"；提交信息语言选择 = 英文 conventional commits；
  范围选择 = 分逻辑提交并推送 `main`。
- 推送前检查：`git status` 中不包含 `.env`、密钥、证书、数据库转储、日志；
  仅按**显式路径**暂存（不使用 `git add -A`），避免把被忽略的运行时目录/临时文件带进去。
- 逻辑提交划分（按主题，且保证每个提交**可构建**）：
  1. `docs(media): add Media Engine Phase 3 server audit and design`（本任务 2 份文档）
  2. `feat(mobile): media engine phases 0-2 and quote/image-editor work`（`apps/mobile_flutter/**`）
  3. `feat(web): gallery image editor demo and registry parity`（`frontend/**`、`packages/ui-contracts/**`）
  4. `docs(workflow): record media engine phases 0-3 in architecture, verification and state index`（其余 `docs/**`）

## 交接与回退

- 已确认根因/已排除假设：
  - **已确认（关键）**：E2EE 上传链路中服务器**从不**收到明文摘要（`chatflow_media` 在 Megolm 密文内；
    上传请求只带密文，`third_party/matrix/lib/src/room.dart:883,925-939`；ADR-0060 §4）。
  - **已确认**：Matrix 侧已存在可复用的服务端媒体对象骨架（摘要索引 + 逐用户引用 + 宽限期 + 隔离墓碑 +
    崩溃恢复），Phase 3 是"抽象 + 扩展"，不是"替换"。
  - **已确认**：业务侧（Moments/Avatar/渲染）完全没有内容寻址、没有引用计数、没有 GC/配额/计量/指标；
    三个读取端点无鉴权；头像/渲染 URL 的 TTL 由客户端 `expires_in` 决定（可到 7 天）；
    朋友圈引用写入不校验 TTL（可"洗白"过期链接）。
  - **已确认**：客户端**没有任何可续传上传**，失败即整请求重试（60 s / 20 s 总时限）。
  - **已排除**：把"明文哈希交给服务器"作为 E2EE 去重手段（ADR-0060 明确否决，本设计继承并给出技术论证）。
  - **已排除**：在 E2EE 域由服务端生成 preview/多档位视频（服务端无明文/无密钥 ⇒ 不可能）。
- 待办及验收失败项：无阻断项。实现前需用户决策：设计文档附录 C 的 Q1–Q10（尤其 Q1 去重选型、Q3 受众级令牌）。
- 已发布与仅候选的区别：**全部仅为本地文档候选**（本轮按用户授权提交并推送 GitHub，但**未构建、未部署**）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不涉及生产；设计 §14.2 明确每个迁移阶段的可回退动作。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：① `git log` 是否已包含本轮提交；② 设计文档顶部"Architecture Design Only"声明仍在
  （防止后续被误当作已实现）；③ `docs/architecture/media-engine-phase3-server-audit.md` 的"未确认项"是否被新的实地证据更新。
