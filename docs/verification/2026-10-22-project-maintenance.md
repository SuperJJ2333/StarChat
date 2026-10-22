# 2026-10-22 项目维护验证与 Git/worktree 审计

本文件是第一轮历史快照。用户随后授权的索引、隔离环境、资料归档与清理结果见[第二轮验证](2026-10-22-project-maintenance-followup.md)；保留下面的首次失败与当时结论，不覆盖历史证据。

观察结束：2026-10-22T22:05:25.693444+08:00。本次只增加维护文档及任务证据、更新 docs 入口；未修改产品代码，未发布。

[计划](../superpowers/plans/2026-10-22-project-maintenance.md) · [任务](../workflow/tasks/2026-10-22-project-maintenance.md) · [项目梳理](../reports/2026-10-22-project-map.md) · [Agent 指南](../runbooks/agent-maintenance.md)。

## 身份与初始状态

- 工作目录 `D:/pythonProject/outsource/StarChat`，Windows，PowerShell 7/UTF-8；本次结束 HEAD `5c83a08a09b985146bc507a1608cb2153d361e48`，与初始相同。
- Python 3.12.10 (`py -3.12`)，裸 python 3.11.11，Node 22.22.2，Flutter 3.44.9 / Dart 3.12.2，Compose v5.5.1，CodeGraph CLI 1.6.0。
- [初始 status](artifacts/2026-10-22/project-maintenance/git-status-before.txt)、[初始 worktree 列表](artifacts/2026-10-22/project-maintenance/worktrees-before.txt)、[初始分支](artifacts/2026-10-22/project-maintenance/branches-before.txt)。
- 初始 tracked 修改是 `docs/workflow/current-state.md`、`frontend/download.html`、`frontend/downloads/android-release.json`，另有未跟踪的 ADR/计划/证据/任务记录。本任务没有暂存、提交、还原这些文件。
- [配置与锁文件 SHA-256](artifacts/2026-10-22/project-maintenance/input-hashes.json)、[源码符号/导入/哈希清单](artifacts/2026-10-22/project-maintenance/source-inventory.json)。这些是本次观测身份，不代表其他工作树或线上产物。
- 根无 `.codegraph/`，按用户仓库规则跳过图分析/建索引；CLI 可用并非命令缺失。用 rg、源码阅读和 AST 完成替代报告。

## 实测结果

| 命令/阶段 | 真实结果 | 证据 |
| --- | --- | --- |
| `git fetch --all --no-prune` | 退出 0，新增两个远程引用；没有 push | [日志](artifacts/2026-10-22/project-maintenance/fetch.log)、[结果](artifacts/2026-10-22/project-maintenance/fetch-result.json) |
| `pwsh -NoProfile -File scripts/verify.ps1` | 退出 1；业务 pytest 退出 2、12 个收集错误 | [完整日志](artifacts/2026-10-22/project-maintenance/verify.log)、[退出/时间](artifacts/2026-10-22/project-maintenance/verify-result.json) |
| verify 前置门禁 | Repository policy、Deployment policy、Template unit、RenderOnly 通过 | 同上 |
| verify infra | 905 passed / 20 skipped / 0 failed | 同上 |
| verify Getui | 38 passed，2 warnings（Starlette/httpx 弃用） | 同上 |
| verify Matrix Bot | 9 passed | 同上 |
| `npm --prefix frontend test` | 退出 1；563 total / 556 pass / 7 fail / 0 skip | [日志](artifacts/2026-10-22/project-maintenance/frontend-tests.log)、[退出/时间](artifacts/2026-10-22/project-maintenance/frontend-result.json) |
| `flutter analyze --no-pub`（本机 SDK 绝对路径） | 退出 0；No issues found | [日志](artifacts/2026-10-22/project-maintenance/flutter-analyze.log)、[退出/时间](artifacts/2026-10-22/project-maintenance/flutter-analyze-result.json) |
| `py -3.12 scripts/verify_ui_contract.py` | 退出 0，34 components / 535 screens | [结果](artifacts/2026-10-22/project-maintenance/contracts-result.json) |
| `py -3.12 scripts/export_openapi.py --check` | 退出 1，Settings 短信有效期校验阻断 | [结果](artifacts/2026-10-22/project-maintenance/contracts-result.json) |
| `import app.main` | 成功；未启动服务 | 本会话执行输出；仅 import smoke |
| `py -3.12 -m alembic heads`，CWD 业务 API | 成功，`0095_wallet_source_alerts (wallet_access) (head)` 单 head | 本会话执行输出；没有数据库写入 |
| 静态 inventory 脚本 | 退出 0，293 Python 文件 AST 语法通过 | [源码清单](artifacts/2026-10-22/project-maintenance/source-inventory.json) |

verify 使用 `PYTHONDONTWRITEBYTECODE=1`、`PYTEST_ADDOPTS=-p no:cacheprovider`，避免生成额外 Python cache；未改测试选择以避开失败。综合验证中后续 Flutter boundary、UI/import/AST/Alembic/OpenAPI 阶段因失败没有执行；表中独立检查单列，不能把它们说成完整 verify 通过。RenderOnly 按原脚本生成本地 data 配置，没有启动容器。

### 失败诊断与未执行项

1. **业务测试收集**：12 项错误均关联 `No module named tests.business_api`。同解释器、PYTHONPATH 下观察到 `tests.__file__ = D:/pentest_ws/strix/tests/__init__.py`，`app.__file__` 是当前仓库 business-api。已经确认测试包被外部包遮蔽，尚未修复全局/虚拟环境，不声称业务测试通过。
2. **前端 7 项失败**：`download-published-2196.test.mjs` 三项、`download-redirect.test.mjs` 一项、`home-ios-download.test.mjs` 一项、`orbit-production.test.mjs` 两项。断言引用 2213/2205 或旧下载 script 参数，而初始工作区下载页含 2233/2215。没有修改页面或断言；先核对最终合并/发布来源。
3. **OpenAPI**：`Settings` 从 CWD 本地配置取得 `sms_aliyun_code_valid_minutes=5`，当前验证器要求 15，导出在比较契约前失败。没改 `.env`，没关闭验证器，尚不能评价实际契约漂移。
4. **未执行**：完整 Flutter test、APK/IPA 构建、浏览器 smoke/截图、Linux 专有门禁、数据库迁移和生产/真机。纯文档维护无产品改动；合并已因现有失败停止，不为获得形式上的构建结果发布或操作生产。
5. **已有警告/跳过保留**：infra 20 skipped，Getui 2 warnings，业务收集阶段 1 warning；未解释到每个跳过条件，不能视为相应平台集成覆盖成功。

## Git 合并结果

- 目标：`main`，由本地分支追踪与 `refs/remotes/origin/HEAD -> origin/main` 确认。
- fetch 后 `origin/main...main` 为 **0 behind / 36 ahead**。本地独有范围为 `be207f0fece77f0a4585790d7c0932368ac63146..5c83a08a09b985146bc507a1608cb2153d361e48`，不是本次新合并范围。[36 提交清单](artifacts/2026-10-22/project-maintenance/main-unpushed-commits.txt)。
- [所有本地分支相对 main/远程的提交计数](artifacts/2026-10-22/project-maintenance/local-branches.json)供后续逐支审查；不能因分支在本机就推断已批准集成。
- **未执行合并**：初始主工作区不干净、来源分支未唯一指定，且完整验证和前端检查失败；按用户要求停止。
- 本次新增合并提交范围：空；冲突文件：无（未启动 merge，不等于已经验证不存在潜在冲突）。未提交、未推送、未强推、未 rebase/reset/cherry-pick、未改写 Git 历史。

## C 盘 worktree 审计与清理清单

只检查 `git worktree list --porcelain` 登记的本仓 C 盘路径，共 **39** 项；D 盘主工作树和 D 盘全部关联 worktree 均不处理。`rev-parse --path-format=absolute --git-common-dir` 用于核对归属。

**实际删除 0，失败的 remove 调用 0，保留 39。** 30 项至少一个 Git 条件不通过；另外 9 项 Git 条件通过，但都包含被忽略的历史验证资料，部分还有 `.env/data`，其保留/归档状态未证实。未发出 `git worktree remove`，未用强制删除。

CIM 检查了 879 个进程的 ExecutablePath/CommandLine，没有匹配这些 worktree 路径；这不覆盖仅通过 cwd 或文件句柄占用的进程，不能作为“已证明无占用”。未终止任何进程。[进程证据](artifacts/2026-10-22/project-maintenance/process-audit.json)。忽略资料仅列路径，不读取或输出秘密正文。

表中“未推送”= HEAD 中任何已 fetch 远程分支均不可达的提交数；“未合 main”= `main..HEAD` 数；数字不是当前分支相对其 upstream 的 ahead。detached 无关联分支，用 HEAD 身份判断。此保守算法不把 patch 等价/cherry-pick 当祖先合并，也不自行认定废弃。

| 登记路径 | 关联分支 / HEAD | 状态项 | 未推送 | 未合 main | 结论/依据 |
| --- | --- | ---: | ---: | ---: | --- |
| `C:/Users/Administrator/.codex/worktrees/admin-entry-merge/StarChat` | `detached` / `ae3a26dedf` | 168 | 0 | 0 | 保留：未提交/未跟踪；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/android-0433-rollback-2206/StarChat` | `detached` / `0392e41af0` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat` | `detached` / `9bc0950141` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/android2214-release/StarChat` | `codex/android2214-release` / `2775108df6` | 0 | 9 | 73 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/auth-login-2178/StarChat` | `detached` / `0ec8106ae8` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat` | `detached` / `a0e3a892ff` | 7 | 0 | 0 | 保留：未提交/未跟踪；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-android-fgs/StarChat` | `codex/im-android-fgs` / `99980f0e20` | 0 | 1 | 1 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-ios-push-policy/StarChat` | `codex/im-ios-push-policy` / `de7953ad29` | 0 | 1 | 1 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-ios-storage-gate/StarChat` | `codex/im-ios-storage-gate` / `2092398787` | 0 | 6 | 42 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-media-budget/StarChat` | `codex/im-media-cache-index` / `896e8e77fc` | 0 | 3 | 26 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-media-cache-regression/StarChat` | `codex/android2214-native-static` / `c7e9c83889` | 0 | 3 | 91 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-media-cache-review/StarChat` | `codex/im-search-grid-final-review` / `102ef5f872` | 0 | 12 | 100 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-media-hash/StarChat` | `codex/im-media-hash` / `78133078d7` | 0 | 7 | 12 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-media-outbox/StarChat` | `detached` / `df1b3e92f1` | 0 | 3 | 54 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-media-reliability/StarChat` | `codex/im-media-reliability` / `1848ef61ee` | 0 | 1 | 1 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-mention-pages/StarChat` | `codex/im-mention-pages` / `8df1feea20` | 0 | 3 | 11 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-push-reliability/StarChat` | `codex/im-push-reliability` / `9d32bdfdf0` | 0 | 1 | 1 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-pusher-reconcile/StarChat` | `codex/im-pusher-reconcile` / `9172e85827` | 0 | 8 | 8 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat` | `codex/android-consent-20261016` / `74cf7217c0` | 7 | 0 | 160 | 保留：未提交/未跟踪；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-runtime-bounds/StarChat` | `codex/im-runtime-bounds` / `e9480c7da4` | 0 | 4 | 33 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-runtime-sampling/StarChat` | `codex/im-runtime-evidence` / `9ee608a550` | 0 | 2 | 31 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-send-scheduler/StarChat` | `detached` / `f4d445840b` | 0 | 3 | 3 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-worker-active-lease/StarChat` | `codex/im-worker-active-lease` / `9d2b3127a7` | 0 | 15 | 103 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-worker-claim-fencing/StarChat` | `codex/im-worker-claim-fencing` / `9920947c34` | 0 | 1 | 45 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-worker-entry-guard/StarChat` | `codex/im-worker-entry-guard` / `29be40a244` | 0 | 5 | 65 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-worker-lease-repro/StarChat` | `codex/im-worker-lease-repro` / `9e036261be` | 0 | 2 | 30 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/im-worker-lease-review/StarChat` | `detached` / `9e036261be` | 2 | 2 | 30 | 保留：未提交/未跟踪；未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/installer-s3-cdn/StarChat` | `detached` / `adadcdf37b` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat` | `codex/interactive-cache-startup-20261016` / `8535e07f98` | 0 | 9 | 239 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat` | `detached` / `24aaa41ce6` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/main-wallet-search-20260930/StarChat` | `detached` / `05c05793cf` | 20 | 0 | 0 | 保留：未提交/未跟踪；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/media-send-startup-2214/StarChat` | `codex/media-2215-final-gates` / `5e1ad763ad` | 0 | 1 | 128 | 保留：未推送提交；未合 main，未获废弃依据；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/network-failure-diagnostics/StarChat` | `detached` / `bccd9492af` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/restore-identity-moments/StarChat` | `detached` / `971fb50d19` | 75 | 0 | 0 | 保留：未提交/未跟踪；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat` | `detached` / `be207f0fec` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/wallet-alert-only-payout-void/StarChat` | `detached` / `902c16b8df` | 10 | 0 | 0 | 保留：未提交/未跟踪；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/wallet-monitor-t2/StarChat` | `detached` / `b9eca8a419` | 40 | 0 | 0 | 保留：未提交/未跟踪；含忽略资料 |
| `C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat` | `detached` / `526e81e228` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |
| `C:/Users/Administrator/.codex/worktrees/withdrawal-quote-policy/StarChat` | `detached` / `ac3c956dc5` | 0 | 0 | 0 | 保留：含忽略资料；未证明句柄无占用 |

完整逐项 status、忽略路径和远程包含关系见 [worktree-audit.json](artifacts/2026-10-22/project-maintenance/worktree-audit.json)，[可复现只读脚本](artifacts/2026-10-22/project-maintenance/audit_worktrees.py)。未执行 prune：初始列表有 D 盘 prunable 条目，全仓 prune 会超出只处理 C 盘的范围。

## 审查和下一步

规格自查先于质量/安全自查：已覆盖结构、模块/调用链、配置/数据流、风险、命令、Git 条件与逐项 worktree 清单；明确 CodeGraph/合并/清理未完成的边界。随后检查路径、源码符号、工具实测和敏感信息边界；文档链接及范围最终结果见同目录 document-check.json。

- 先确定现有 main 未提交内容的归属及应合入的具体来源分支；不自动暂存或丢弃。
- 新建或复用隔离的 Python 3.12 测试环境，核对测试包导入和本地配置，修复环境后重新运行失败门禁；前端版本断言需先与发布来源对齐。
- 对 9 项 Git 条件通过的 worktree，先核对忽略证据/配置/数据的留存方案并完成句柄检查，再复验状态；满足后使用 Git 原生 remove。
- 需要 CodeGraph 图结果时，由用户决定索引后补充；本次仅提供静态替代报告。
