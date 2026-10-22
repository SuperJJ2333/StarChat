# 项目梳理、Agent 指南与 Git/worktree 维护计划

状态：按 2026-10-22 本会话用户明确维护指令执行；不修改产品行为。

## 范围与所有权

- 当前工作树：`D:/pythonProject/outsource/StarChat`；初始 HEAD `5c83a08a09b985146bc507a1608cb2153d361e48`。
- 仅维护本计划、`docs/reports/2026-10-22-project-map.md`、`docs/runbooks/agent-maintenance.md`、`docs/README.md`、`docs/workflow/tasks/2026-10-22-project-maintenance.md`、`docs/verification/2026-10-22-project-maintenance.md` 和本任务的 `docs/verification/artifacts/2026-10-22/project-maintenance/`。
- 保留初始未提交和未跟踪文件，不提交、暂存或还原其他任务内容。Git 合并、worktree 移除仅在用户规定门禁全部满足时执行。

## 执行步骤

1. 读取结构、README、依赖/构建配置、根及相关下级规则；保存 Git/worktree 初始证据。
2. 检查 CodeGraph 可用性；根目录没有 `.codegraph/` 时遵守用户仓库规则，使用文件清单、符号/导入和调用点追踪，不自动建索引。
3. 核查入口、领域模块、调用链、配置与数据流，按现有文档分层撰写报告与 Agent 操作指南，区分静态事实、实际执行和 TODO。
4. `git fetch --all --no-prune` 更新远程引用；识别 main 和候选分支差异，预检测试环境并执行适用现有检查。工作区脏、来源分支不明确、测试失败或冲突均停止合并，保存原因。
5. 仅对 `git worktree list` 中 C 盘关联路径检查状态、远程可达性、是否合入 main、锁定/占用和忽略文件。删除前列明清单；只有全部满足时才使用 `git worktree remove`，不使用强制删除、不删主树或未合入工作。
6. 先自查需求覆盖，再检查文档链接、命令、保密及范围；记录执行退出码、工具/输入身份、耗时与下一步，交付四项结果和未完成项。

## Review Focus

- 不把 main 的 2213 源码与状态索引中的 2233 发布证据混为一谈。
- CodeGraph 命令存在不等于有索引；静态追踪不声称涵盖动态分派。
- 已 cherry-pick 不等于 Git 祖先已合并；只按可证明事实清理。
- detached HEAD 仍可能存在独有未推送提交；忽略文件可能含签名或唯一产物。
- 不用成功的子检查掩盖完整验证失败；不删除 D 盘的过期 worktree 元数据。

## 第二轮授权与步骤（2026-10-22）

用户明确要求完成索引、归属/候选确认、独立 Python 3.12 复现和九个工作树资料保全。本轮不修业务代码；先完成验证再讨论合并，不执行 merge/push。

第二轮文档所有权增加 `docs/reports/2026-10-22-codegraph-supplement.md`、`docs/verification/2026-10-22-project-maintenance-followup.md`；归档库位于保留的 `interactive-cache-startup` 工作树的本日 verification artifacts 目录，按受限 ACL 保全。不把归档或索引加入 Git。

1. 保存主工作区变更的字节与 SHA，逐文件比对候选分支，识别发布回填及尚未提交的独有内容。
2. 在本任务 `followup/` 证据目录建立独立 Python 3.12 环境；核对原 lock 的平台兼容，保留任何安装失败。仅用本地测试配置处理环境差异，不改业务/测试源码。
3. 初始化本地 CodeGraph，排除运行数据、历史构建/验证及工作树，保留现有业务源码/Matrix fork；允许修改被忽略的 `codegraph.json` 并备份原配置。索引和查询结果绑定当前 main SHA，分别记录可解析的动态分派边与无法证明的调用。
4. 对九个候选先清点忽略资料、重解析点/大小与重复内容，按可用磁盘保全并做恢复校验；秘密资料只进入访问受限、Git 忽略的本地归档。先验证进程/句柄再复查 Git，只在全部满足时使用非强制 `git worktree remove`。
5. 更新本任务文档和证据，不覆盖其他任务发布状态。新增输出归本任务 `docs/verification/artifacts/2026-10-22/project-maintenance/followup/` 与对应 Markdown 附录。
