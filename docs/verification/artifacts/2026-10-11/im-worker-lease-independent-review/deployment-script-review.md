# R9a 部署脚本独立审查（执行前）

## 当前最终结论：SPEC → QUALITY 均 PASS，可进入已授权的有界部署

最终脚本 SHA256：`dc5e6dc8f02f6f1d01d79bb635fcab6545b57b105aa048a34d1cc542c4a94b44`，8691 字节。2026-10-11 13:54:27+08 完成最终替身验证，**11 PASS / 0 FAIL，exit=0**。本结论取代下文初始暂缓结论；不适用于 `215afc47...`、`828cc82e...`、`79c5d533...` 旧脚本。

规格/领域阶段先确认修复仍只切 business-worker、原候选/回退镜像和配置保护不变；质量阶段再逐条验证以下不确定结果与 DB 边界，无剩余阻断：

- 外层 guard 使用 `start_new_session=True`、480s，覆盖内部最大 420s 预算。外层 timeout 的 TERM/KILL 只指向本次新会话的进程组；清理 `try/finally` 保证清理本身失败也抛 `UncertainSwitch`。
- `wait` 的其他异常，以及固定 guard 将内部 Compose 超时折叠出的非零退出，均转为 `UncertainSwitch`。上层写 FAILED/recovery_required，明确不自动回退；不能把 Docker daemon 未决操作当成已经取消。须另行读取稳定后的实际状态再恢复，禁止直接重复脚本。
- 只有 guard 已明确成功且后验失败时才走 guard rollback。回退本身若不确定，保持 FAILED/rollback_failure_type，不写 rolled_back=true。
- DB 前后验在 `e.begin()` 中先 `SET TRANSACTION READ ONLY`，再 `SET LOCAL statement_timeout='5s'`；连接超时 3s、docker exec 12s。inspect/source/ps 10s 有界。未输出 DSN、token 或查询正文以外的数据库内容。
- 两次 PROCESSING=0 仍是非原子抽样前提；期间旧 worker 仍可能开始新事件，现有 SIGTERM/租约/at-least-once 边界不变。没有宣称 drain、无损停机或 R9b 已解决。

本地验证从精确脚本 SHA 选择真实 AST 函数及顶层错误处理分支，所有 subprocess、os.killpg、路径写入均为无副作用替身；没有导入/执行部署脚本顶层，没有 Docker、网络、数据库或真实进程信号。验证逻辑分支不等同 Linux 进程树/真实 daemon 故障演练；不确定结果始终停住正是此限制下的安全边界。候选容器 gate 与原生 PostgreSQL 证据分别沿用既有结果，不重复声称本次新执行。

证据：`test_deployment_failure_boundaries.py`（SHA `4e2f6132c1edc48fbe603e8893733a19c74883c727fd23bd702e225fb3a6e1dd`）、`deployment-failure-boundaries-final-dc5e.log`、`deployment-failure-boundaries-final-dc5e-result.json`。覆盖成功、新会话、外层超时、进程组已消失、guard 内层超时表现的 exit1、清理 PermissionError、wait OSError、成功后后验失败回退、回退不确定、SQL 和 inspect 期限。

根因补测还保留了 `deployment-cleanup-red-79c5.log` / `deployment-cleanup-red-79c5-result.json`（exit1）：79c5 清理 PermissionError 会漏出普通异常；最终版本转为 UncertainSwitch 后该用例转绿。root 已确认旧版本未执行。

可部署边界：root 可在已有授权范围内，按最终 SHA 和现有前置 guard 执行候选 `sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf` 的 business-worker 单服务切换；任一现场漂移/活跃 processing/不确定切换均按脚本停止。此审查没有实施部署，不代表后验已通过，也不改变财务、历史死信、schema 或 R9b 的限制。

## 初始审查记录（问题已由上述最终版本收口）

审查对象：`C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-11/im-worker-jit-deployment/deploy.py`，初始 SHA256 `215afc47bd9c8eaefa752469bb4cac916b69b669a220c190f358bf3165749dfa`。

仅本地源码/已有准备与候选验证证据审查；未运行部署脚本、未连接服务器。本文件是审查意见，不能当作发布结果。

### 初始结论：暂缓执行，需处理两项

1. **P1：外层超时可使部署与回退交叠。** `deploy.py:54` 的 guard subprocess timeout=240s，小于所调用 `scripts/business_release_guard.py` 的 render 30s、两个角色分别 90s+cleanup 15s、Compose up 180s 的累积预算。若外层先到时，Python subprocess.run 只终止 guard 直接子进程，尚在运行的 docker compose 后代进程可继续切换；随后 `deploy.py:110-113` 立即启动 rollback，不能证明旧操作已经停止。外层预算应覆盖内层边界；不确定超时须先收敛该次进程组/切换状态再回退，保留失败状态，不能并行发两次 Compose 切换或把不确定结果标成已回退。
2. **P1：DB 前/后验无界，可能卡住自动恢复。** `schema():20-22` 和 `processing_count():41-43` 无 read-only transaction / statement_timeout，外层 docker exec 亦未设 timeout。尤其部署后的 schema 后验可能一直等待而不进入回退。补只读事务、statement_timeout≤5s、连接超时及短的外部执行预算；不输出 DSN 或 DB 参数。超时应进入明确失败/收敛路径。

以上已先通知 root：不要按此初始 SHA 执行。等待 root 修改后，仅复核增量和新的 SHA。

## 已确认的正面边界

- `--service business-worker` 与 guard 的 `--no-deps --pull never --no-build` 限定实际切换，不把 API 镜像同时发布；两个角色仍完整做 refresh protocol guard。
- 镜像使用固定 sha256；API 与 worker 旧 ID/镜像、原 Compose 文件 SHA、私有冻结配置 SHA、运行 Config/HostConfig/挂载项均有比较；候选只有 worker.py overlay，旧源码已按 root 的现场证据绑定。
- 原日志用私有目录硬链保留已捕获 inode，未 truncate；它不是原子完整日志快照，后续新增/轮转仍需说明捕获范围。
- 两次 PROCESSING=0 已在代码中明确为抽样前提，不是原子 drain；没有租约 exactly-once 承诺。guard 执行期间旧 worker 仍可领取，现有 SIGTERM/租约恢复边界仍适用，不能据此承诺零重复外部通知。
- 切换后有 worker readiness、期望 image、运行配置、源码 SHA、schema、公共健康和其他容器 ID 检查；失败使用同一协议 guard 回退，私有输出不公开敏感配置。
- 已有 `validation-result.txt` 显示候选镜像合成 gate 为 7 PASS / 1 strict XFAIL / 1 PG skip；独立 owner 的本机 PostgreSQL gate 已另有证据，不能将容器中的 PG skip 改称本次容器原生通过。

源码 R9a 两阶段 PASS 与此部署脚本暂缓结论分别成立；部署脚本问题不改变 worker 补丁的源代码审查结论。
