# R10 有限运行采样

## 恢复入口、授权与所有权

- 已批准计划 `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md` R10 的有限日志分桶范围，由主任务明确授权实现、测试、提交和服务器只读采样；不部署、不安装常驻 agent。
- native 独立工作树 `C:/Users/Administrator/.codex/worktrees/im-runtime-sampling/StarChat`，分支 `codex/im-runtime-sampling`，基线 `1284772e1743b584533333de5d2493477289c754`。
- 所有权仅 `scripts/collect_im_runtime_sample.py`、`scripts/tests/test_collect_im_runtime_sample.py` 与本报告/专属 artifacts。未改 R7a、metadata、AppHome、服务端业务或原生生产源。
- 原候选：10 项专项 PASS、Black/Ruff PASS，服务器单次只读采样 exit 0。独立 SPEC → QUALITY 发现候选命名与继承管道超时两项缺口；后续修复与待复审边界见本文末尾。

## 行为与分母

旧 `post-deploy-observe.py` 只识别状态码位于请求引号之后的访问日志，漏掉 Synapse 状态码在引号之前的格式；用整个 URL 的子串识别路由还会被 query 参数中的 recovery/media 等词误导。两条原行为合成 RED 已实际观察到，分别在新分类器转绿。

新脚本固定四个服务，仅执行 `docker inspect` 白名单格式、`docker logs --since --until --tail` 和一次 `docker stats --no-stream`。固定窗口默认 300 秒、最多 3600 秒；每服务默认最多 10000 行/2MiB、字节上限最高 8MiB；每命令默认 10 秒/最高 30 秒，另最多 2 秒等待终止后的直接子进程回收。读取使用非阻塞管道，不创建后台读取线程，不等待其他进程释放继承的 stdout。没有任意服务名、路径或 shell 参数入口。停止的只有采样器自己创建的 Docker CLI 直接子进程，不终止其后代或其他进程，容器不变。

- 每个观察行恰好归入 HTTP 完成、请求开始、没有完成状态、traceback 头、截断末行、超长行或未匹配行之一；`sum(line_buckets) == log_lines`。
- 所有固定 route/status 桶之和等于 `http_completed`。支持 Uvicorn/nginx、Synapse、httpx 的明确格式，不丢弃未知行。
- 开始记录数等于“已配对完成 + 未观察到完成”。完成记录数等于“已观察到开始 + 未观察到开始”。仅 Synapse 方法/序号在当次有界内存中相关联，不输出/持久化原标识。重复开始 ID 不覆盖旧记录；无相关标识的开始独立计数。
- 窗口边界、日志级别和截断会造成未配对；0 个开始记录不代表系统没有未完成请求。命令失败报告 missing/error，不转成零次成功。
- `long_sync_30s_zero_db_fetch_candidates` 仅在固定 sync 路由、200、timeout=30000、服务耗时至少 29 秒且 `[0 dbevts]` 同时成立时计数。它是零数据库事件读取的长轮询候选；不能据此断言空闲、无消息或空响应，缓存事件和其他响应段未被该日志测量，也不是性能 SLO。输出 schema 已从 1 升为 2。
- tail 达上限只能报告可能截断；字节截断、命令超时、半行分别标注，无法知道的丢样总量不编造。
- 输出只含固定分类/错误枚举、数字、镜像 digest 和采样时间。正文、原 URL/query、token、CID、请求标识、用户/设备标识和 stderr 原文均不输出。不把恢复路由 HTTP 次数当成用户恢复次数；不把供应商 HTTP 200 当设备收到、系统展示、声音或点击。

## 验证与采样

证据目录 `docs/verification/artifacts/2026-10-11/im-runtime-sampling/`：

- `parser-red.log`：旧解析器两项真实行为 RED。
- `contract-red.log`：追加分母/边界/采集接口测试时的失败，包含尚未实现接口；不把这些缺接口错误当全部行为 RED。
- `focused-green.log`：`python -m unittest discover -s scripts/tests -p test_collect_im_runtime_sample.py -v`，10 PASS、exit 0、约 0.17 秒。
- `quality-green.log`：Black 检查与 Ruff 无告警；真实字节上限/子进程超时、只读命令集合、固定窗口、坏数据和敏感哨兵均有断言。
- `input-hashes.json`：脚本、测试、计划、旧观察器及只读采样输出的 SHA-256。Python 3.11.11 / Windows 10 / PowerShell 7，UTF-8 无 BOM；标准库实现，无依赖锁变化。
- `verify-preflight.json`：verify.ps1 存在但隔离树无 `.env`，未导入生产配置跑整个服务/移动构建链。新独立脚本不改变业务/移动行为，全量共享候选 gate 留主任务；不声称完整 verify.ps1 exit 0。

服务器窗口 `2026-10-11T04:30:44.065715+00:00` 至 `04:35:44.065715+00:00`，通过既有 jumper、主机密钥校验和 Python stdin 执行一次，未上传落盘脚本。四服务 12 个只读命令成功；当前口径的聚合 JSON 见 [修正标签样本](artifacts/2026-10-11/im-runtime-bounds/runtime-sample-corrected.json)，所有分母守恒，没有 tail/字节/超时截断，traceback 头为 0。该文件只修正旧计数标签与解释，保留原窗口及所有数值，并记录原样本 hash；未重新采样。原 `im-runtime-sampling/runtime-sample.json` 作为历史证据保留，其含 idle 的字段名已被判定不准确，不得按其旧名称解释。

| 服务 | 观察行 / HTTP 完成 / 未匹配 | 状态 | 已观察的限制 |
| --- | --- | --- | --- |
| business_api | 576 / 366 / 210 | running、healthy、restart 0 | recovery_route:200 为 60 次路由响应；other:401 为 6，other:429 为 2，不能推断具体用户恢复或探针来源 |
| getui_bridge | 0 / 0 / 0 | running、未提供 health、restart 0 | 空窗口不是设备投递成功证据 |
| synapse | 167 / 111 / 56 | running、healthy、restart 0 | sync:200 为 10，其中零 DB fetch 长轮询候选 10 |
| sync_worker | 40 / 23 / 17 | running、healthy、restart 0 | sync:200 为 23，其中零 DB fetch 长轮询候选 20 |

一次 stats 的 CPU 分别约 1.28%、0.17%、0.35%、0.42%，仅为当次瞬时资源值。镜像 digest、内存、PID 数均在聚合 JSON；不推断峰值/容量或长期稳定。

首个启动使用 `scripts/starchat-server.ps1` 入口，但该脚本不转发 pipeline stdin，远端 Python 等待输入；已只终止精确识别的本任务 SSH 子进程。随后沿用相同 jumper/端口/StrictHostKeyChecking 参数直接把脚本经 stdin 送入 ssh，8.7 秒完成，不改代理或服务器文件。这是启动方式修正，不是业务请求重试或隐藏采样失败。

## 阶段、剩余边界与回退

实际主动阶段未持续计时，精确总墙钟未知；中途按主任务优先级审查 R8 原生目录候选，发现项留在 `r8-native-review/review.md`，不计作本采样实现耗时。上述测试与采样时间来自命令输出和输出窗口。

本批未添加客户端端到端阶段 tracing、真实设备推送回执、event-loop lag 的新服务指标、告警或容量压测。它们仍属于 R10 其他验收，不能因此勾满 R10。回退仅移除这个独立脚本；没有服务/数据库/schema/容器状态变更需要回退。

## 独立审查后续修复

独立审查与后续实现记录在 [im-runtime-bounds/task.md](artifacts/2026-10-11/im-runtime-bounds/task.md)，该目录包含原 frozen 的 SPEC/domain → QUALITY 报告、两条新 RED、Windows/Linux 新输入测试与文件 hash。修复工作树基于 `214e0887`，所有权仅脚本、专项测试与相关报告。复审须由其他审查者完成；本报告不将原作者修复后的自测称作独立双审通过。
