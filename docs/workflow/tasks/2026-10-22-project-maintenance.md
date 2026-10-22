# 项目梳理、Agent 文档与 Git/worktree 维护

## 恢复入口

- 目标/授权：2026-10-22 当前用户要求读取仓库、编写梳理报告与 Agent 文档、按门禁合并 Git 分支并清理本仓 C 盘无用 worktree；不作无关代码修改、不强推、不改写历史。
- 关联计划：[本任务计划](../../superpowers/plans/2026-10-22-project-maintenance.md)。没有产品行为改动，无新增 ADR。
- 当前状态：第二轮维护完成。已明确来源并保全既有改动/发布身份，完成真实 CodeGraph 图查询、独立环境全部门禁观察与九项安全清理。原完整门禁失败，未合并、未修业务代码；Docker 测试容器最终状态未确认。最新结果见[第二轮验证](../../verification/2026-10-22-project-maintenance-followup.md)，下面第一轮表格保留为历史。
- 负责人/工作树：本会话主 Agent，`D:/pythonProject/outsource/StarChat`；没有创建子 Agent 或新工作树。
- 文件所有权：本计划、项目报告、CodeGraph 补充、Agent 指南、`docs/README.md` 一行导航、本任务记录、两轮验证报告及 `docs/verification/artifacts/2026-10-22/project-maintenance/`；另有本轮授权的忽略索引配置/数据库、隔离环境和候选工作树下受保护归档库。业务源码、原有发布文件与其他任务证据均不改。
- 源码 commit：`5c83a08a09b985146bc507a1608cb2153d361e48`，前后相同。
- 最后更新：2026-10-23，第二轮最终核验已结束；精确命令及验收时间见 followup 下结果 JSON，路径仍沿用 2026-10-22 任务开始日期。
- 下一条可执行操作：按第二轮报告分别处理测试依赖、诊断/iOS/发布契约、15 份主树独有文档整合与隔离 PostgreSQL 门禁；Docker 恢复后核验本任务测试容器。不得跳过失败直接合并。

## 第一轮验收台账（历史）

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 缺口 |
| --- | --- | --- | --- | --- | --- |
| M1 | CodeGraph 梳理或明确替代 | CLI 1.6.0；无 `.codegraph/`，遵守仓库要求跳过建索引，完成静态追踪 | [报告](../../reports/2026-10-22-project-map.md)、AST 源码清单 | 不涉及 | 真正图分析待用户决定索引 |
| M2 | Agent 文档含环境、命令、流程、调试、Git和清单 | 按现有 runbooks 规范新增指南并链接入口 | [指南](../../runbooks/agent-maintenance.md)、document-check.json | 本地文档 | 未执行命令均标 TODO/限制 |
| M3 | 更新远程、通过门禁再合并 | fetch 成功；测试失败按要求停止 | [验证报告](../../verification/2026-10-22-project-maintenance.md) | 无 | 12 业务收集错误、7 前端失败、OpenAPI 配置失败、脏工作区及来源选择 |
| M4 | 只清理满足全部条件的 C 盘 worktree | 审计 39；30 有 Git 门禁问题；9 有忽略证据及占用确认缺口 | 逐项 JSON/Markdown；process audit | 删除 0 | 先保全资料、确认句柄与弃用状态，再复查 |

## 版本与证据

| 平台/服务 | 实际版本/环境 | 来源 commit | 工件/签名 | 证据位置及 SHA | 发布观察 |
| --- | --- | --- | --- | --- | --- |
| 当前 main | Flutter 声明 0.4.44+2213 | `5c83a08a` | 本次无构建/签名 | [输入哈希](../../verification/artifacts/2026-10-22/project-maintenance/input-hashes.json) | 未访问生产 |
| 本机验证 | Python 3.12.10/裸 python 3.11.11、Node 22.22.2、Flutter 3.44.9/Dart3.12.2、Windows | 同上，含初始未提交静态发布文件 | 不适用 | [环境](../../verification/artifacts/2026-10-22/project-maintenance/environment.json)、[源码清单](../../verification/artifacts/2026-10-22/project-maintenance/source-inventory.json) | 不是线上验收 |

完整命令、真实退出码、通过/失败/跳过、warning 和未执行项见验证报告。此次测试是本地执行，没有 CI run/job ID；未复用他人成功结果替代本次失败。独立 UI/Flutter 检查不改变完整 verify 失败结论。

## 阶段计时

| 阶段 | 开始（UTC+08:00） | 结束 | 类型/并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- |
| 初始阅读/技能/结构 | 精确起点未记录 | 21:46:35 前 | 主动+工具 | 不估算精确分钟 | 保存证据 |
| Git fetch | 21:46:35.875 | 21:46:38.536 | 工具/Git | 约 2.66 秒，含保存初始状态；fetch-result.json | 审计分支/worktree |
| worktree/源码调查 | 精确起点未独立记录 | 21:53 前 | 主动+工具，与门禁重叠 | audit/source-inventory JSON；不虚构纯主动耗时 | 文档 |
| 根 verify | 21:50:21.954 | 21:51:30.483 | 工具/checks | 68.53 秒，退出 1 | 保留失败并停止合并 |
| 前端 test | 21:50:32.168 | 21:50:43.779 | 工具/checks，与 verify 重叠 | 11.61 秒，退出 1 | 记录 7 项失败 |
| Flutter analyze | 21:52:59.570 | 21:53:36.541 | 工具/checks | 36.97 秒命令墙钟；分析器报告 31.7 秒，退出 0 | 文档验收 |
| 文档、审查与链接验证 | 起点未独立记录 | 见 document-check.json | 主动+工具 | 先需求覆盖、后质量/安全，非独立第三方审查 | 交付 |

整体主动/工具拆分及初始总墙钟未知；上述并行区间不能简单相加。无外部批准等待，未重复全量门禁；首次大范围文档输出过长后改为限定文件/符号读取，避免继续扫描历史资料。

## 第一轮交接与回退（历史）

- 已确认：外部 `tests` 包遮蔽、本地短信配置校验失败、旧下载版本断言与初始工作区页面不一致；未修产品代码或全局环境。
- 未完成：真正 CodeGraph 图分析、合并、实际清理；各自条件和下一步见台账。不把调查完成写成合并/清理完成。
- 无生产发布、备份/恢复或平台安装。脚本按原 verify 生成本地 data 配置，未启动容器。
- 没有新分支、提交或远程写入；所有既有工作树保留。本任务文档可单独审阅并按明确文件路径提交，不使用 `git add .` 混入其他工作。
- 本任务启动的 verify、前端 test、Flutter analyze 和审计进程均结束；没有残留服务、隧道或后台帮助进程。
- 下次先重新 fetch/status/worktree list，检查 HEAD 与证据输入身份，再恢复本任务。不要据本次零进程匹配直接删除目录。

## 第二轮完成台账

| ID | 结果 | 证据与剩余事项 |
| --- | --- | --- |
| M1 | 用户授权后完成 CodeGraph 索引与实际调用/动态分派补充 | [图报告](../../reports/2026-10-22-codegraph-supplement.md)；main 图，不冒充候选运行时 trace |
| M2 | Agent 指南、项目报告与验证记录更新 | [指南](../../runbooks/agent-maintenance.md)，最终链接/身份检查；TODO 均注明环境/范围原因 |
| M3 | 来源确定为 `codex/interactive-cache-startup-20261016@8535e07f`，范围 239 提交；保全 70 个既有文件及发布工件 | 独立环境 main 业务 1 fail、候选业务 2 fail；候选移动 1 fail、前端 6 fail；环境/PG 缺口详见第二轮报告。未合并、未提交、未 push |
| M4 | 九项归档完成并经非强制 Git 成功移除，0 失败 | 555,418 文件、ZIP 9,650,207,176 bytes，623 链接安全解除；其他 C/D 工作树、主树和归档库保留 |

主树 `5c83a08a` 与候选 `8535e07f` 均未改变；Android2233 SHA/签名保留，iOS2215 失败到授权发布的顺序保留。原始未提交快照、逐文件来源、所有失败日志、归档 manifest、链接关系和占用检查均位于本任务 followup 证据目录及受限 ACL 归档库。

阶段计时见[第二轮报告](../../verification/2026-10-22-project-maintenance-followup.md)；完整业务检查约 51 分钟，两棵树并行；归档约 25 分钟、复核约 14 分钟、移除约 9 分钟，与验证重叠，不相加当作主动耗时。Flutter 历史全量证据经过 2,154 输入和 4 份证据重新哈希后复用；新增 analyze 实测通过。

全部本任务测试、索引、归档、清理及 Docker CLI 超时监护进程已结束。候选临时 `.env` 按创建哈希核验后清理，主树 `.env` 未改。唯一无法确认的临时资源是 Docker 无响应期间的 `starchat-popup-2193-d6b911ea4d79`，没有盲目重启 daemon 或操作他人容器。归档库自身未来清理前须先迁移保全。
