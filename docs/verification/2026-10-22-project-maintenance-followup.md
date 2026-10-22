# 项目维护第二轮验证与交接

状态：第二轮调查与维护已完成，最终核验跨至 2026-10-23；验证存在明确失败和环境缺口，未合并、未修业务代码。时区 UTC+08:00。

授权：用户要求归属澄清、明确来源分支、独立 Python 3.12 复核、归档并复查九个 worktree、完成 CodeGraph 索引及真实查询；本轮不修业务代码，先验证再讨论合并。关联[计划](../superpowers/plans/2026-10-22-project-maintenance.md)、[任务](../workflow/tasks/2026-10-22-project-maintenance.md)、[第一轮证据](2026-10-22-project-maintenance.md)。

## 1. 主工作区归属与候选来源

目标分支 `main` 保持 `5c83a08a09b985146bc507a1608cb2153d361e48`。重新 fetch 后 `origin/main` 为 `be207f0fece77f0a4585790d7c0932368ac63146`，main 领先 36。候选来源确定为 **`codex/interactive-cache-startup-20261016`**，HEAD `8535e07f98e27047251f4f2c78202c24ad31a304`，工作树 `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat`。

main 是候选 HEAD 的祖先，差异范围为 `5c83a08a..8535e07f`，共 239 个提交；未来具备 fast-forward 的拓扑条件，但不代表门禁、未提交文档整合与审查已经满足。本轮没有 merge、commit、push、reset、stash、rebase 或改写分支指针。其他本地分支不能因为时间较早就自动纳入来源。

证据：[239 个提交](artifacts/2026-10-22/project-maintenance/followup/candidate-239-commits.txt)、[分支覆盖](artifacts/2026-10-22/project-maintenance/followup/candidate-branch-coverage.json)、[逐文件归属表](artifacts/2026-10-22/project-maintenance/followup/main-change-ownership.md)、[机器可读归属](artifacts/2026-10-22/project-maintenance/followup/provenance-resolved.json)。这里的归属指内容来源的可验证关系，不猜测自然人作者或谁批准了每份文档。

候选范围并非只有客户端：API/Worker 及其测试共 27 个文件变化，含 Outbox claim/fencing/租约续期、事件循环和链观察错误处理。main 与候选分别执行完整门禁有不同输入依据，不能拿 main 的测试结果直接覆盖候选。

| 本轮开始的 76 个未提交文件 | 数量 | 处理 |
| --- | --- | --- |
| 与候选 Git blob 完全一致 | 50 | 包括已修改的下载页和 Android registry，视为候选内容回填；不再次当作独立业务修改提交 |
| 与 `im-reliability` worktree 的未提交副本完全一致 | 5 | iOS2215 分发/弹窗、Android2217/杀毒相关任务与验证记录；保留来源和历史授权 |
| 仅在主工作区发现，未与任何本地/远程 ref 或其他 worktree 完全匹配 | 15 | 含 `current-state.md`、启动投影 ADR/计划、运行调查和发布证据；单独保全，未来逐份与候选差异审阅 |
| 本维护任务自身文档 | 6 | 独立文件所有权；随后增加本报告与 CodeGraph 补充 |

全部 76 个文件在本轮修改前已按原始字节保存为 [main-uncommitted-preservation.zip](artifacts/2026-10-22/project-maintenance/followup/main-uncommitted-preservation.zip)，逐文件读回校验。20 个不与候选完全一致的既有文件生成了 [documentation-differences](artifacts/2026-10-22/project-maintenance/followup/documentation-differences/) 差异。没有覆盖原有 70 个非维护文件；`current-state.md` 的交付状态仍原样保留。

15 个主树独有文件不是可以自动丢弃的“重复资料”。后续合并前，先将它们作为独立证据变更整理到明确的集成提交/工作树；当前只完成来源分类与保全，没有冒称这些未提交变更已全部整合入 Git。

## 2. 发布状态与工件身份

| 项目 | 保留/核验结果 |
| --- | --- |
| main 客户端声明 | 0.4.44+2213，与现行下载元数据不是同一身份 |
| 候选客户端声明 | 0.4.64+2233；本轮不重新构建或发布 |
| Android2233 最终 APK | `docs/verification/artifacts/2026-10-22/android2233-release/arm64-final-r2/final.apk`；73,655,386 bytes；SHA-256 `77c17e4c96b24569690a80f1954f00acb267b01b407941ffe2b95c51621bf573` |
| APK 源码身份 | 发布记录绑定 `6cbc09d5da26a8443df77d3522fbc22c5856f774`；不能因候选 HEAD 更晚就改写该身份 |
| APK 签名 | apksigner 36.0.0 verify 通过；签名证书 SHA-256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` |
| iOS2215 历史工件 | 文档记录 0.4.46/2215，37,250,414 bytes，IPA SHA-256 `4087d408f5e294fe2482a6ccebef65bc0aeb73123cab25fb5a4547ad8ebd7aba`，Bundle ID `com.liuhetong.liuhetongMobile` |
| iOS 授权顺序 | 严格签名检查曾因期望 `HY9Q7Q35S5`、实得 `7XL5R8V6RC` / `com.qiming.newhqzl299` 失败；随后记录用户明确授权发布该特定文件。保留两阶段记录，未将失败改成通过；本轮未重新验 IPA 或访问生产 |

证据：[release-identity.json](artifacts/2026-10-22/project-maintenance/followup/release-identity.json)、[APK 签名输出](artifacts/2026-10-22/project-maintenance/followup/release-signature.txt)、既有 [iOS 分发任务](../workflow/tasks/2026-10-15-ios2215-static-distribution.md)。下载页和 registry 的原始哈希在归属清单中，均与候选内容一致。没有为消除测试失败回退发布版本。

## 3. 独立 Python、依赖锁和配置复现

独立 venv 位于 `docs/verification/artifacts/2026-10-22/project-maintenance/followup/py312`，Python 3.12.10；未使用系统 site-packages，未卸载或改动全局包。通过 [run-isolated-gates.ps1](artifacts/2026-10-22/project-maintenance/followup/run-isolated-gates.ps1) 将未修改的 `scripts/verify.ps1` 中 `py -3.12` / `python` 都路由到此解释器，预检 `app.__file__` 和 `tests.__path__` 都指向各自测试工作树。

| 复现/验证 | 结果 |
| --- | --- |
| 原始锁直接安装 Windows venv | 失败：`uvloop==0.22.1 does not support Windows`，未修改生产锁 |
| 临时 Windows 派生锁 | 仅剔除 uvloop，保留其余锁定版本；安装 API、Bot/Getui 测试依赖成功，`pip check` 退出 0 |
| 原始锁在 Linux Python3.12 | 固定镜像 `python:3.12.11-slim@sha256:47ae396f09c1303b8653019811a8498470603d7ffefc29cb07c88f1f8cb3d19f`；原样安装、`pip check`、fastapi/sqlalchemy/uvloop 导入均退出 0 |
| 锁身份 | 主/候选 `requirements.lock` 相同；SHA-256 `f64b119c66265cb59b3272d074afe32b4560da1715f30499580c3a046346bf8f` |
| 外部 tests 包遮蔽 | 独立环境中不再复现；两个工作树都通过导入预检并进入业务用例执行，第一轮 12 个 collection errors 已分离为全局环境污染 |
| 原始 `.env` 配置问题 | 隔离解释器仍复现短信有效期 5、校验要求 15 的失败，证明其独立于导入污染 |
| 门禁用配置 | 仅进程环境设 `BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES=15`；不修改主树 `.env`。候选原无 `.env`，临时复制其 `.env.example` 并记录创建哈希，完成后只清理本轮创建且未被修改的副本 |

Linux 容器只挂载锁和本任务验证脚本/输出，不启动业务栈，不连接业务数据库或消费队列；使用 `--rm`。Windows 派生锁验证不能冒充原生产锁在 Windows 原样可安装；Linux 安装通过也不能代替完整 Linux 业务集成测试。

证据：[原锁安装结果](artifacts/2026-10-22/project-maintenance/followup/install-original-lock-result.json)、[Windows 安装结果](artifacts/2026-10-22/project-maintenance/followup/install-windows-lock-result.json)、[环境预检](artifacts/2026-10-22/project-maintenance/followup/environment-preflight.json)、[Linux 锁验证](artifacts/2026-10-22/project-maintenance/followup/linux-lock-result.json)、[完整安装快照](artifacts/2026-10-22/project-maintenance/followup/installed-freeze.txt)。

## 4. 完整门禁与候选测试

主树/候选分别从原始完整脚本开始执行，均因业务 pytest 失败退出 1，未进入脚本后续阶段；后续阶段另行补查，不覆盖原始退出码。

| 原脚本阶段 | main | 候选 |
| --- | --- | --- |
| Repository / Deployment policy、Template、RenderOnly | 通过 | 通过 |
| Infra | 905 pass / 20 skip | 915 pass / 20 skip |
| Getui | 38 pass，3 warnings | 51 pass，3 warnings |
| Bot | 9 pass | 9 pass |
| Business API + Worker | **3,932 pass / 127 skip / 1 fail**，2 warnings | **4,037 pass / 142 skip / 2 fail**，2 warnings |
| 原完整脚本总结果 | **退出 1**，22:33:26 → 23:24:14 | **退出 1**，22:33:13 → 23:24:56 |

两个工作树共同失败于 `tests/business_worker/test_support_recovery_compatibility.py::test_disabled_funds_worker_obeys_attribution_unique_and_empty_receipt_gates`。`load_probe` 用 `importlib` 加载本工作树 `docs/verification/artifacts/2026-09-30/support-worker-compatibility/worker_probe.py`，该忽略文件缺失，抛 `FileNotFoundError`。这是受跟踪测试依赖未随 Git 提供的历史临时脚本，不是 tests 包导入污染，也不是本次清理范围中的文件。需要后续把合法测试依赖整理成可复现的受跟踪 fixture/支持模块；本轮未从未知副本拼补或改测试。其路径与调用关系已由 [CodeGraph 精确查询](artifacts/2026-10-22/project-maintenance/followup/codegraph-failed-worker-test.md)确认。

候选另失败于 `tests/business_api/test_client_diagnostics.py::test_dart_performance_enum_wire_names_match_server_allowlists`：Dart 的 PerformanceStage 比服务端允许集合多 11 个值：`association_preparation_started/done`、`outbox_preparation_started/done`、`room_preparation_started/done`、`room_display_cache_hit/miss`、`local_timeline_sql_started/done`、`identity_lookup_started`。这是客户端/服务端诊断契约不一致。独立定向重跑两项仍为 **2 failed**（1.57 秒），排除了把它们仅归因于长测试并发负载的解释；未修改枚举或放宽校验。见 [完整定向错误](artifacts/2026-10-22/project-maintenance/followup/candidate-focused-failures.log)。

跳过不计为通过。尤其候选新增 `test_worker_active_lease_postgres.py` / `test_worker_claim_fencing_postgres.py` 明确要求 `IM_WORKER_LEASE_TEST_DATABASE_URL` 指向隔离本地 PostgreSQL；本轮未提供该变量。移动发布测试自建的 PostgreSQL 不替代这些租约/并发测试。TODO：Docker/独立数据库可用后，配置隔离库并执行候选相关 PG 门禁；Windows、缺少外部服务等其余跳过原因需在下次相应环境运行时用 `-rs` 完整输出，不推断全部 142 项原因相同。

候选 Node 测试：570 total / 564 pass / 6 fail，分别涉及 `download-published-2196`（3 项）、`download-redirect`（1 项）、`orbit-production`（2 项）；仍有旧 Android 2213 路径/版本、iOS 警告和安装行为断言，与现行发布输入不一致。保留当前已授权发布内容，后续按发布规范评估页面和断言，不为变绿直接回退版本。本轮不修改页面、业务逻辑或测试期望。

业务测试后的阶段使用 [run_remaining_gates.py](artifacts/2026-10-22/project-maintenance/followup/run_remaining_gates.py) 独立补查，结果如下；不把补查结果改写为原完整脚本成功：

| 补查阶段 | main | 候选 |
| --- | --- | --- |
| Python 移动边界 | **377 pass / 20 skip / 1 error** | **376 pass / 23 skip / 1 fail** |
| Flutter/HTML UI 契约 | 34 components / 535 screens，退出 0 | 34 components / 540 screens，退出 0 |
| API import / AST | 退出 0；287 文件语法通过 | 退出 0；288 文件语法通过 |
| Alembic heads / offline SQL | 单 head `0095_wallet_source_alerts`，退出 0 | 同左，退出 0 |
| OpenAPI check | 退出 0 | 退出 0 |
| Compose 示例配置 | 退出 0 | 退出 0 |

main 的移动 error 是隔离 PostgreSQL 模块 teardown 的 Docker CLI 超时终止。候选移动失败为 `test_ios_handoff_release_version.py::test_unsigned_pipeline_uses_current_source_version_at_every_handoff_boundary`：工作流未包含测试期望的 `--build-name=0.4.64 --build-number=2233`。需核对 iOS 独立交付策略与工作流/测试契约，不因此改写既有 iOS2215 发布状态。候选静态隐私扫描最终完成，没有发现该检查定义的禁用字面量；没有缩小其扫描范围或跳过它。

**OpenAPI 原先的配置阻断已独立复现，使用进程内正确参数后两棵工作树的契约检查均通过。** 离线 SQL 检查没有执行数据库 upgrade；Compose config 通过也不代表 Docker daemon 可用。见 [main 补查结果](artifacts/2026-10-22/project-maintenance/followup/main-remaining-results.json)、[候选补查结果](artifacts/2026-10-22/project-maintenance/followup/candidate-remaining-results.json)。

日志：[main verify](artifacts/2026-10-22/project-maintenance/followup/main-verify.log)、[candidate verify](artifacts/2026-10-22/project-maintenance/followup/candidate-verify.log)、[candidate frontend](artifacts/2026-10-22/project-maintenance/followup/candidate-frontend.log)。任何单独补跑不改变原始完整脚本的失败结果。

候选 `flutter analyze --no-pub` 本轮实测退出 0，No issues found。共享 Flutter 测试采用输入一致的既有证据：本轮重新校验发布 manifest 的 **2,154 个文件**、4 个历史证据文件及 pubspec.lock，差异为 0；候选移动目录与发布源 `6cbc09d5` 的 Git diff 为空。原记录为 Flutter3.44.9/Dart3.12.2、6,378 pass / 9 skip / 0 fail；这是历史证据复核，不标记为本轮新跑 Flutter 全量测试或原生构建。原生 DLL、平台/真机未观察等限制继续保留。见 [输入复核](artifacts/2026-10-22/project-maintenance/followup/mobile-evidence-recheck.json)、[历史共享门禁副本](artifacts/2026-10-22/project-maintenance/followup/shared-flutter-record.json)、[本轮 analyze](artifacts/2026-10-22/project-maintenance/followup/candidate-flutter-analyze-result.json)。

## 5. 删除前 worktree 清单与保全

九项均来自本仓 `git worktree list`，位于 C 盘、detached HEAD，已是 main 的祖先且全部提交被远程 refs 覆盖；既非主树也非主仓库。其余 30 个 C 盘 worktree 的首轮脏/未合并/未推送记录保留，本轮不重试删除它们。D 盘条目不在清理范围，不运行全仓 prune。以下为操作前已列明的清单，九项现均已成功移除。

| 完整路径 | 关联分支/HEAD | 删除前判断依据 |
| --- | --- | --- |
| `C:/Users/Administrator/.codex/worktrees/android-0433-rollback-2206/StarChat` | detached `0392e41af0de` | main 祖先、无远程不可达提交；已归档，待最终占用/状态复核 |
| `C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat` | detached `9bc09501412a` | 同上；69 个目录 symlink 需先安全解除 |
| `C:/Users/Administrator/.codex/worktrees/auth-login-2178/StarChat` | detached `0ec8106ae8c9` | 同上 |
| `C:/Users/Administrator/.codex/worktrees/installer-s3-cdn/StarChat` | detached `adadcdf37bd4` | 同上；127 个目录 symlink 需先安全解除 |
| `C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat` | detached `24aaa41ce61a` | 同上 |
| `C:/Users/Administrator/.codex/worktrees/network-failure-diagnostics/StarChat` | detached `bccd9492af16` | 同上；1 个指向 E 盘构建目录的 junction 需先安全解除 |
| `C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat` | detached `be207f0fece7` | 同上；426 个链接需先安全解除 |
| `C:/Users/Administrator/.codex/worktrees/wallet-ui-polish/StarChat` | detached `526e81e2284a` | 同上 |
| `C:/Users/Administrator/.codex/worktrees/withdrawal-quote-policy/StarChat` | detached `ac3c956dc5e3` | 同上 |

归档库为 `C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat/docs/verification/artifacts/2026-10-22/project-maintenance-archive-vault`，不属于待删除九项。ACL 仅当前用户与 SYSTEM 完全访问、关闭继承。归档含忽略的证据、配置、数据和必要构建产物，不输出秘密内容，不提交到 Git。可再生缓存按清单排除，链接保存目标关系。每个 ZIP 和 manifest 均有 SHA-256；所有文件都逐字节读回核验，9 项归档错误数为 0。

归档合计 **555,418 个常规文件 / 9,650,207,176 bytes ZIP**；排除的 4,380 个可再生缓存路径另列在 manifest。移除前再次对源文件逐项哈希核对，并验证 ZIP/manifest 身份，9 项全部通过。

证据：[archive-results.json](artifacts/2026-10-22/project-maintenance/followup/archive-results.json)、[无跟随链接审计](artifacts/2026-10-22/project-maintenance/followup/reparse-audit.json)。归档库未来自身清理前必须先迁移保全，不能因其处于被忽略目录而删除。

恢复工具 [restore_ignored.py](artifacts/2026-10-22/project-maintenance/followup/restore_ignored.py) 只向新建受限 ACL 目录恢复常规文件，逐文件核对 SHA，不覆盖已有工作树、不自动创建指向外部的链接。已用归档中一个证据文件完成恢复抽查并验证哈希；全体文件另已通过 ZIP 全量回读校验。链接需依据 manifest 与单独 detachment 记录，在目标范围确认后恢复，不能盲目解压重建外部链接。

本机 Git 2.51.0.windows.1 的隔离沙盒测试发现 `git worktree remove` 会沿被忽略的 junction 删除目标哨兵内容；该测试只使用本任务自建文件，没有触碰真实项目资料。[沙盒结果](artifacts/2026-10-22/project-maintenance/followup/removal-probe/result.json)与 [unlink 验证](artifacts/2026-10-22/project-maintenance/followup/removal-probe/unlink-result.json)表明，先用非递归 `os.rmdir` 解除目录链接可保留目标。

因此实际删除先检查：精确绝对路径及祖先均不逸出、不为 reparse root；归档哈希与源文件再次核对；完整扫描没有遗漏链接；所有链接已忽略且未跟踪；进程命令行/可执行路径和打开句柄均无匹配。保存链接关系后只解除链接，再复查 Git/占用、外部目标元数据，最后执行不带 `--force` 的 `git worktree remove`。失败则保留并记录原因，不强制清理。

句柄工具来源为微软官方 [Sysinternals Handle](https://learn.microsoft.com/en-us/sysinternals/downloads/handle)，下载包 Authenticode 已验证为 Microsoft 签名；只用查询参数，没有关闭任何他人句柄或进程。

## 6. CodeGraph 与文档结果

实际索引、查询、接口动态分派候选和局限见[CodeGraph 补充](../reports/2026-10-22-codegraph-supplement.md)。索引 complete，2,602 files / 53,036 nodes / 218,898 edges，pending refs/changes 为 0；没有把初轮静态报告冒充图结果。Agent 文档沿用仓库 `docs/runbooks/` 规范更新为[维护指南](../runbooks/agent-maintenance.md)，根 AGENTS 未修改。

## 7. 最终清理、验证与下一步

**清理已完成：上述九项全部由 `git worktree remove` 成功移除，退出码均为 0，失败项为 0。** 先安全解除 623 个已忽略、未跟踪的 reparse links，保存链接关系，没有递归操作链接目标。完整记录见 [清理前复核](artifacts/2026-10-22/project-maintenance/followup/cleanup-review.json)、[移除结果](artifacts/2026-10-22/project-maintenance/followup/cleanup-results.json)；每项保留命令、HEAD、三次进程/句柄检查和起止时间。

清理前逐项复核为 23:04:07 → 23:17:51；实际移除为 23:18:40 → 23:27:54。没有 `--force`，没有 prune，没有删除分支或主树。注册 worktree 从 66 变为 57，集合变化严格等于这九项；其余 30 个 C 盘关联 worktree 保留，D 盘条目不变。归档库位于保留的候选工作树中。

测试环境新增阻断：移动边界用例会自行启动固定 digest 的本地隔离 PostgreSQL 容器，仅用于合成测试数据、随机 localhost 端口，不访问生产。main 在模块 teardown 的 `docker rm --force` 阻塞，候选在 `docker info` 阻塞；另行 `docker ps` 及 15 秒 `docker version` 探测也不响应。只对核验为本任务子进程的 Docker CLI施加 30 秒上限，未停止 daemon、重启 Docker/WSL 或操作他人容器。见 [无响应探测](artifacts/2026-10-22/project-maintenance/followup/docker-unresponsive.json)、[超时明细](artifacts/2026-10-22/project-maintenance/followup/docker-cli-timeouts.json)。测试容器 `starchat-popup-2193-d6b911ea4d79` 的最终移除状态暂未确认，待 Docker 恢复后先核对身份再清理；不能把此状态写成已清理。

最后一次 15 秒 Docker inspect 仍超时，测试容器状态保持未确认，见 [最终容器状态](artifacts/2026-10-22/project-maintenance/followup/test-container-final-status.json)。本任务测试、清理、索引与超时监护进程均已结束；没有启动生产服务。候选临时 `.env` 与创建时 SHA 完全一致，已只删除此本轮副本，见 [配置清理回执](artifacts/2026-10-22/project-maintenance/followup/candidate-env-cleanup.json)。主树原始 `.env` 未修改。

移除后重新哈希全部九个 ZIP/manifest，全部与移除前一致；九个原目录均不存在，Android2233 APK SHA 不变，见 [最终保全检查](artifacts/2026-10-22/project-maintenance/followup/preservation-final-check.json)。文档链接、70 个既有文件哈希、源码/分支身份及 worktree 差集由 [最终文档检查](artifacts/2026-10-22/project-maintenance/followup/followup-document-check.json)核验；CodeGraph 最终仍 complete、pending refs/changes 为 0。先自查用户需求与范围，再核查路径/失败口径/保密和删除安全；这是本会话自查，不冒称独立第三方审查。

全工作区 `git diff --check` 退出 2，指出原有 `docs/workflow/current-state.md:5504` 的 EOF 空行，并提示现有文件的 CRLF/LF 转换。该文件及发布文件 SHA 与维护前相同，故不为清掉警告而改写他人状态；本任务文件另行做范围内格式检查。全局检查的失败保留于 [最终范围检查](artifacts/2026-10-22/project-maintenance/followup/final-scope-check.json)，不冒称全工作区干净。

| 阶段 | 起止（2026-10-22，UTC+08:00） | 类型与证据 |
| --- | --- | --- |
| CodeGraph 完成 | 索引时间 22:28:46；命令结束 22:29:08 | 工具；status/init JSON，提取耗时以 CLI 原日志为准 |
| main 原 verify | 22:33:26 → 23:24:14 | 工具/并行门禁，约 50 分 48 秒 |
| 候选原 verify | 22:33:13 → 23:24:56 | 工具/并行门禁，约 51 分 43 秒 |
| 九项归档/完整回读 | 22:38:43 → 23:03:32 | 工具/与门禁重叠，约 24 分 49 秒 |
| 移除前完整复核 | 23:04:07 → 23:17:51 | 工具，约 13 分 44 秒 |
| 九项 Git 移除 | 23:18:40 → 23:27:54 | 工具，约 9 分 14 秒 |
| main 后续补查 | 23:24:43 → 23:39:52 | 含 Docker 阻塞及受控超时，约 15 分 9 秒 |
| 候选后续补查 | 23:25:59 → 23:51:08 | 含 Docker 阻塞、完整静态扫描，约 25 分 9 秒 |

主观分析/文档时间未独立计量，不虚构总主动耗时；并行区间不可相加。独立环境安装、Linux 锁验证、Node/analyze 的精确时间在各自 result JSON。没有外部审批等待；未重新构建已验证且输入不变的 APK/Flutter 全量测试。

后续顺序：

1. 对主树独有 15 份资料和 `im-reliability` 的 5 份记录逐份审阅并形成明确的集成提交；保留发布授权顺序、工件 SHA/签名和 main/candidate 的不同来源身份。
2. 单独任务修复可复现测试依赖、客户端/服务端诊断契约和下载页测试与发布规范的关系。本轮未作这些业务/测试修改。
3. 恢复本地 Docker 可用性后核验上述唯一测试容器的状态；配置明确的隔离 PostgreSQL 运行候选租约/并发门禁，补足平台特有覆盖。
4. 以上门禁通过并完成必要审查后，再讨论把 `5c83a08a..8535e07f` 合入 main。现阶段不能把拓扑可 fast-forward 当作合并许可或验证通过。

已完成：文件归属与原始字节保全、发布 APK 身份复核、独立解释器/锁/配置复现、原始完整门禁的失败定位、九项归档与安全清理、真实 CodeGraph 索引/查询、Agent 文档更新。Git 合并、失败修复及未具备环境的门禁没有冒称完成。
