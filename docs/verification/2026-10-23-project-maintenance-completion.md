# 项目维护剩余事项 · 2026-10-23

状态：完整候选门禁已通过，正在执行已批准的本地合并和索引收尾。用户已授权诊断契约最小修复、文档冲突双边保全整合和本机 Docker 重启。

工作树：`C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat`；分支 `codex/maintenance-completion-20261023`，起点 `8535e07f98e27047251f4f2c78202c24ad31a304`。源发布分支仍为 `codex/interactive-cache-startup-20261016`。

证据位置：主工作树 `docs/verification/artifacts/2026-10-23/project-maintenance-completion/`。上一轮报告与失败记录保留，禁止覆盖为通过。

## 已确认结果

- 78 份既有/维护文件归档 `main-before.zip`，全部 SHA256 回读验证。15 份预演冲突已获用户明确批准按[资料整合方案](../archive/2026-10-23-maintenance/README.md)处理。
- 诊断 API 补入现有 Dart 客户端的 11 个阶段，继续使用固定 Literal 白名单；生成 OpenAPI 同步。未改客户端/资金/身份安全逻辑。
- 缺失 Worker 夹具从 4 个 SHA256 一致的历史工作树恢复到 `tests/fixtures/support_worker_probe.py`；保留原有归属唯一性、资金禁用、审计和账本断言。
- 未签名 iOS CI 的构建、验包与交接文件名同步源版本 0.4.64+2233；这不是已签名 iOS 2215 的重新发布。
- 3 个确定性失败先复现；相关 222 项通过。前端 6 个陈旧发布身份断言修复后，全量 570 项通过。Node 首次使用不支持的命令参数退出 9，修正为项目 `npm test` 后通过，失败日志保留。
- 本机 PostgreSQL 18.3 的独立实例仅监听 127.0.0.1，使用本任务专属数据库；14 项 Worker claim/fencing/续租并发门禁通过。不把该结果称为生产 PostgreSQL 版本覆盖。
- Docker 恢复后，在既有固定镜像 PostgreSQL 16.9 上另跑同样 14 项，全部通过，专属临时容器及匿名卷已清理。旧容器 `starchat-popup-2193-d6b911ea4d79` 的名称、镜像、创建时间、loopback 端口先核对，删除事件与独立查询确认不存在。
- SPEC → 独立 QUALITY/SECURITY 审查通过。任务恢复入口过时的问题已修正；15 个标准补丁经过实际 `git apply` 还原与哈希验证，185 个维护文档链接通过。混合换行作为历史证据保留，归档内 `.gitattributes` 禁止 patch 的文本换行转换。
- 主工作区 78 份文件已保全于 `2e6cbcef6b33dcc917bcdb5c1dd94c60fa6e68f3`；最小修复独立提交为 `c1ca0636f334d2c9cdeb4143c1f6410b78b6e3e2`。78 份原始工作文件字节保持，尚未合并。
- 完整门禁首轮因本任务 `PYTEST_ADDOPTS` 的 Windows 反斜杠路径解析失败（736 pass/20 skip/179 setup errors），并非业务断言失败。修正为正斜杠后重跑；首轮 JSON/log 完整保留。正常 Docker restart/shutdown 命令曾无响应，获批后仅恢复本地 Docker Desktop 后台及 `docker-desktop` WSL 运行时，引擎 29.8.2 已响应。

## 发布与资料边界

第二次完整执行 `full-verify-r2` 在业务阶段退出 1：4,043 pass / 127 skip / 11 setup errors，耗时 3,058.93 秒。11 项均由同一个 Redis 夹具首次连接 `TimeoutError` 引起；单独重跑原文件 12 pass，随后新增确定性超时注入回归，红灯证实错误，最小等待修复后 13 pass。测试夹具修复提交 `fb6537aa8e19edced6787b5878510c67d679de18`，规格与质量/安全独立复核均通过；未改 Redis 业务逻辑。第三次完整执行 `full-verify-r3` 正在运行，前次错误日志不覆盖为成功。

Android 2233 / iOS 2215 发布文件、包字节及签名身份保持。严格 iOS 签名失败和用户随后授权发布的时间顺序保持。无构建新包、无生产操作、无推送或历史改写。

上一轮 9 个工作树已安全移除，不重复操作；受限归档库仍保留在原候选工作树中。主树 CodeGraph 报告绑定上一轮 `5c83a08a`，不冒充新候选图分析。

## 待完成

实际合并、隔离 PostgreSQL 实例关闭、合并后的 CodeGraph 索引/查询和最终输入一致性检查。完整候选门禁、旧 Docker 测试容器清理、文档还原/链接验证、规格及质量安全审查、主树保全提交均已完成。

## 第三次完整门禁结果

`full-verify-r3.json`：2026-10-23 06:04:43.1998817 → 06:51:17.6821308（UTC+08:00），退出 0，日志末尾 `Verification: PASS`；临时 `.env` 已按原哈希核对后清理。运行输入与 `fb6537aa` 的代码一致。以下条件跳过不计为通过。

| 检查 | 结果 |
| --- | --- |
| 仓库/部署策略、模板、RenderOnly | 通过 |
| Infra | 915 passed / 20 skipped |
| Getui / Bot | 51 passed（3 条依赖弃用警告）/ 9 passed |
| Business API + Worker | 4,055 passed / 127 skipped / 2 条依赖弃用警告，2,634.67 秒 |
| Python 移动边界 | 399 passed / 1 skipped，53.48 秒 |
| UI 契约 | 34 components / 540 screens，通过 |
| API import / OpenAPI / Compose | 通过 |
| Alembic | 单 head / offline SQL 通过；未执行生产迁移 |
| AST | 独立直连解释器解析 288 个服务文件通过 |
| 前端全量 | 570 passed / 0 failed / 0 skipped |
| Worker PostgreSQL 并发 | 独立 18.3 和固定镜像 16.9 各 14 passed |
| 移动发布 PostgreSQL 及 teardown 专项 | 24 passed；完整移动阶段再次通过 |

本任务 PowerShell 解释器包装函数未将管道正文转发给 `python -`，导致完整脚本的 AST 阶段没有实际输出；因此另将脚本的同一 AST 检查直接管道传入独立解释器，得到明确的 288 文件 PASS（`ast-direct.log`），不把原空输入退出 0 当作语法验证证据。后续包装函数必须同时验证参数和 stdin 转发。

剩余 148 项条件跳过：Infra 20 / 业务 127 均为其他专用 PostgreSQL 环境或进程隔离条件未启用，移动 1 项缺少 Ruby/CocoaPods hook 运行时，逐项原因在 `skips.json`。它们未被改为通过，未禁用任何测试；涉及相应模块的后续修改必须提供其专用数据库与平台门禁。Flutter 6,378 pass / 9 skip 为相同输入的历史证据复核，未新建 APK/IPA，未新跑真机或 macOS 原生构建。

## worktree 清理清单与复核

以下路径均位于 `C:/Users/Administrator/.codex/worktrees/<名称>/StarChat`，第二轮已通过 Git、归档、进程及句柄复核，由非强制 `git worktree remove` 移除；本轮重新核验 9 个 ZIP 的 SHA256 和原路径不存在，未重复删除。关联 HEAD、删除前逐项依据和命令详见[完整清单](2026-10-22-project-maintenance-followup.md#5-删除前-worktree-清单与保全)。

| 名称 | 结果 |
| --- | --- |
| android-0433-rollback-2206 | 已移除，归档复核通过 |
| android2205-sync-deadlock | 已移除，归档复核通过 |
| auth-login-2178 | 已移除，归档复核通过 |
| installer-s3-cdn | 已移除，归档复核通过 |
| ios-media-room-followup | 已移除，归档复核通过 |
| network-failure-diagnostics | 已移除，归档复核通过 |
| search-camera-history-20261003 | 已移除，归档复核通过 |
| wallet-ui-polish | 已移除，归档复核通过 |
| withdrawal-quote-policy | 已移除，归档复核通过 |

失败项 0。原有其余 30 个 C 盘工作树保留；本轮新增 `maintenance-completion` 含未推送提交，继续保留。主工作树及 D 盘条目未清理，没有运行全仓 prune。当前登记 58 个工作树。

归档库仍在保留的 `interactive-cache-startup/StarChat/docs/verification/artifacts/2026-10-22/project-maintenance-archive-vault`，受限 ACL，含配置与数据，不进 Git。任何后续清理必须先迁移保全该库；本轮没有删除其容器目录。
