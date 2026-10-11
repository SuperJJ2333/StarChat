# 端到端架构与性能评审

## 恢复入口

- 目标与授权：2026-10-11 用户要求覆盖 Android/iOS 的九方面端到端技术评审；允许读取可获取的代码、配置、日志、验证和运行信息。此次不实施产品修改、发布、压测、文件清理或发送测试推送。
- 状态：评审完成；问题修复与真机/容量验收未执行，不标记为产品已达标。
- 源码：主目录 main，HEAD `5c83a08a09b985146bc507a1608cb2153d361e48`；开始时 `git status --short` 无输出。根目录无 `.codegraph`，按规则跳过 CodeGraph。
- 文件所有权：主代理仅本任务记录、最终评审及 `docs/verification/artifacts/2026-10-11/e2e-architecture-review/` 自建证据；子代理分别拥有该目录的 push-review.md、client-review.md、backend-review.md。不修改既有任务或 current-state 索引。
- 计划：只读评审按用户九方面清单执行；不执行产品行为变更计划。
- 最后更新：2026-10-11 10:14，Asia/Hong_Kong（UTC+08）。
- 交付：[完整九项报告](../../verification/2026-10-11-e2e-architecture-performance-review.md)，含26项风险/验收缺口、统一设备场景矩阵、建议SLO、路线图及缺失资料。
- 下一条具体操作：后续修复任务先核对当前设备实际iOS最终包SHA与已记录2213是否一致，复用对应成品身份报告，再安排保数据覆盖升级及APNs/CallKit真机验收（N2-1）；同时可分别领取FGS超时、跨房通知节流和媒体API阻塞的有界修复任务。本评审未授权自动发版、换包或实机操作。

## 验收台账

| ID | 评审范围 | 证据方式 | 状态 |
| --- | --- | --- | --- |
| R1 | Android 后台保活 | 原生/Flutter/推送配置、既有测试 | 评审完成；真机Doze/超时/能耗缺口已列 |
| R2 | 双端提醒与声音 | 权限/渠道/APNs/签名/路由/去重 | 评审完成；跨房节流离线复现，最终包真机缺口已列 |
| R3 | 收发与同步 | Matrix SDK/业务接口/重试/容量证据 | 评审完成；端到端百分位与真实群测未知 |
| R4 | UI与弱网 | 缓存/列表/交互/诊断 | 评审完成；历史成绩按版本隔离，缺弱网组合真机 |
| R5 | 内存 | 对象生命周期/缓存上限/已有现场报告 | 评审完成；有风险路径，未证实手机OOM根因 |
| R6 | 媒体与存储 | 文件/缓存/上传下载/生命周期 | 评审完成；同步IO离线复现，服务器大小预检风险已列 |
| R7 | 架构与网络 | 模块/部署/运行快照/可观测性 | 评审完成；瞬时快照不作容量保证 |
| R8 | 目录与归档 | 文件元数据/归档政策/客户端目录 | 评审完成；未移动/删除文件，不能将逻辑长度当可回收量 |
| R9 | 冷温热启动 | 启动链/缓存/升级与历史现场 | 评审完成；缺同构前后启动分位与最终包旧机验证 |

## 阶段计时

| 阶段 | 起止（UTC+08） | 类别 | 结果 |
| --- | --- | --- | --- |
| 初始化、规则与最新状态 | 开始时间未采样；09:18 前 | 主动 | 读取跨会话入口，确认源码身份并三域并行审查 |
| 生产只读快照 | 09:18:06 与 09:18:59 起约8秒 | 工具 | SSH 经既有 jumper；资源、容器身份、限制和短时 PSI/vmstat；exit 0 |
| 客户端/推送/后端并行审查 | 09:18前已开始，完成时点未逐个采样 | 主动/工具 | 三个独立文件所有权；38测试通过，两项合成复现，未触达真实供应商/S3 |
| 主报告归并与指标修订 | 09:35 前，完整开始时点未采样 | 主动/返工 | 采纳iOS内存口径、媒体理论耗时、对账截止与能耗测量边界建议 |
| 规格后质量独立审查 | 09:35–09:37 | 主动 | 先规格PASS，再质量/安全PASS；审查回执单独记录 |
| 媒体上限配置核对 | 09:37:32 观测点 | 工具 | 仅读生产容器两个非敏感配置键，exit0；50M与客户端100MiB差异的提前预检风险 |
| 最终整理与引用核验 | 09:38起，结束以report-verification.json为准 | 主动/工具 | 新增V6-3并复核SDK最终守卫；链接/行号/九项覆盖/产品diff核验 |

总墙钟因起始采样缺失不作精确分钟汇总；并行阶段不能相加。无产品改动，未重复全仓verify或移动包构建；旧设备/历史压测不等同本次实测。

## 版本、测试与证据身份

- 主目录源码身份见恢复入口；报告对应每个源码/历史证据文件的SHA冻结在[report-verification.json](../../verification/artifacts/2026-10-11/e2e-architecture-review/report-verification.json)。生产镜像、容器状态和采样时点见[资源快照](../../verification/artifacts/2026-10-11/e2e-architecture-review/production-resource-snapshot.txt)。
- 推送离线命令：`python -m pytest -q -p no:cacheprovider tests/getui_bridge`，配套PYTHONPATH及PYTHONDONTWRITEBYTECODE；38 passed、exit0，2条已有依赖弃用警告。具体解释器、依赖、源文件身份和时间见[测试日志](../../verification/artifacts/2026-10-11/e2e-architecture-review/push-tests-result.txt)与[源身份](../../verification/artifacts/2026-10-11/e2e-architecture-review/push-source-identity.json)。
- 两项合成复现：[推送跨房节流](../../verification/artifacts/2026-10-11/e2e-architecture-review/push-distinct-room-repro-output.txt)、[媒体事件循环](../../verification/artifacts/2026-10-11/e2e-architecture-review/backend-media-event-loop-probe.txt)，均exit0；它们证明现象，不表示已修复。
- 文档核验命令：`D:/python/python.exe docs/verification/artifacts/2026-10-11/e2e-architecture-review/verify_report.py`、`git diff --check`。最终退出码、报告SHA、有效引用数见核验产物与本次工具记录；无产品变更，不运行新源码构建。
- [独立审查回执](../../verification/artifacts/2026-10-11/e2e-architecture-review/review-receipts.md)。未执行：真实推送、设备安装/清数据、生产压测、资源限制变更、归档删除；各缺口与建议验收在主报告明示。

## 交接与回退

- 已确认：通知CID级节流会跳过第二个不同房间出站机会；async媒体路由可被同步存储阻塞。不能外推为Matrix消息丢失或Synapse全部请求阻塞。
- 待办：主报告全部风险尚未修复；P0为已记录精确iOS回签成品的发布信任闭环，不是已证明真机故障/恶意。
- 发布/回退：本任务仅新增评审与证据，没有候选包、生产写入或需要回退的配置；没有遗留CI、隧道或运行命令。
- 恢复先查：源码HEAD、当前安装包SHA、控制台/OEM配置、设备分布以及现有授权是否变化；不要重跑未变等价测试来替代缺失真机证据。

## 证据边界

- 既有测试属于其记录日期、源码与设备，不自动转化为当前生产性能。
- 端到端延迟、消息到达率、功耗、OOM/ANR率和真机帧率没有分母或设备采样时保留未知。
- 服务器指标仅瞬时与数秒样本，不用于认定峰值容量或客户端OOM。
- 原始证据不包含密钥、令牌、聊天正文或用户个人标识。

## 2026-10-11 服务器复核与修复方案续项

- 用户新增授权：连接服务器自行访问查看，并给出修复方案；未要求本轮实施或部署。09:55+08开始该续项（此前初始化开始时点未单独采样）。
- 用户澄清：Android小米/OPPO/vivo等厂商推送通道受上架审核限制暂不可配置；不是iOS APNs。OEM通道作为待外部条件的任务，不能算当前代码缺陷或假装已验收。
- 目标：把上一轮模板/源码风险与现运行配置、脱敏日志、数据库/队列状态对照，形成审核期间可执行的修复顺序和之后的厂商通道验收。
- 范围/所有权：主代理新增server-followup证据、服务器复核报告和拟议修复计划；push_review仅push-runtime系列与push-plan-notes，backend_review仅backend-runtime系列与backend-plan-notes，client_review仅client-plan-notes。产品与既有评审报告保持。
- 连接：仍用scripts/starchat-server.ps1经既有jumper；日志在服务端聚合，仅输出状态码、计数、选定配置和时间；SQL只读且限定超时。未发送真实消息/推送，未安装、清数据、重启服务或改配置。
- 09:57:36+08第一轮当前运行快照：核心镜像与上一轮一致、主要健康服务正常；日志轮转不一致、单sync上游已由当前nginx配置确认。网关tail50000已截尾，不能称完整24小时分母；后续修正stdout/stderr拼接下的时间边界。
- 现场结论：[服务器复核报告](../../verification/2026-10-11-server-runtime-followup.md)；新SR1为恢复鉴权目标8000与实际8082不匹配，运行模块与本地SHA相同，容器内8000拒绝/8082可连；未读任何密钥或恢复材料。新SR2为核心服务日志轮转不一致。
- 方案：[R0–R11分阶段修复计划](../../superpowers/plans/2026-10-11-im-reliability-remediation.md)，原26项全部映射，新2项另列。Android厂商通道延后，iOS已配置production APNs独立核验。
- 排除的误判：网关所采refresh401全部带既有监控probe标记；当时非probe刷新均200。最近24h新Outbox5222条均PUBLISHED；历史DEAD与已handover的2条旧PENDING不作为当前积压，不自动重放。
- 证据入口：[本轮身份/引用核验](../../verification/artifacts/2026-10-11/server-followup/followup-verification.json)，冻结所有采样文件SHA、当前HEAD和报告/计划SHA；旧评审冻结身份是原时点，不用本次追加任务记录改写旧证据。
- 下一条执行建议：若后续开始实施，先领取R1恢复端口最小修复，补部署拓扑RED与测试身份/keyring的隔离同拓扑回归；R2通知节流/R3媒体IO/R4 FGS可独立并行，R0最终iOS身份同步核对。仍未部署或宣称真机验收通过。

### 续项阶段计时与验证

| 阶段 | 时间（UTC+08） | 结果 |
| --- | --- | --- |
| 恢复规则、授权与OEM澄清 | 09:55–09:57 | 使用既有jumper；明确只读+方案及厂商外部依赖 |
| 首轮主机/路由、推送、PG并行采样 | 09:56:45–10:03:53 | 各证据自带时间/退出码；元数据和聚合输出，禁止原始秘密/正文 |
| 503路径分类与端口依赖核查 | 10:01:19–10:04:02 | SR1证据闭合；8000失败不是所有历史iOS问题的统一归因 |
| 方案整理及原26项映射 | 10:04后至10:13 | 客户端/推送/后端独立笔记；主报告90行、主计划204行，12任务 |
| 规格审查 | 10:13前后 | push_review完整两文档PASS；之后交backend_review质量安全审查 |
| 最终质量/安全审查 | 10:14 | backend_review两文档SHA一致、PASS无阻断；现场查看和修复方案交付完成，产品修复未执行 |
| 文档/身份验证 | 10:13:21首次，最终以核验JSON为准 | 25个唯一本地引用有效、R0–R11齐全、无产品diff；不称产品测试通过 |

所有服务器命令已结束，无新增隧道、远程文件或测试账号。首轮Sygnal安全配置探针exit1后缩小字段成功；一次无效本地glob及未生成子文档读取无结果均已换准确路径，未据失败输出作结论。root探针有一条正则Python SyntaxWarning，采样命令exit0，后续分类探针使用raw regex；该提示与生产服务异常无关。本轮是文档/方案工作，未重复前轮38测试或重新构建移动包。

独立[审查回执](../../verification/artifacts/2026-10-11/server-followup/review-receipts.md)记录规格先于质量及精确文档SHA。续项状态：**完成服务器只读复核与方案交付**；待办是后续实施任务与明确列出的设备/容量验收，不是尚有本轮服务器命令在运行。
