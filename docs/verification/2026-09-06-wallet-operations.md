# 钱包日结、事故处置与监控验证

日期：2026-09-06。范围为已批准钱包安全补充设计的本地业务 API / Worker 实现和无托管商 Sandbox 验证。未发布生产、未执行生产迁移、未触碰真实资金；本轮没有 Flutter UI 或 APK 变更，此前 MI 6 验收证据仍见 `2026-09-06-wallet-application-mi6.md`，没有新增 iOS 验收结论。

## 实现与证据

- 新增日结捕获快照、日期版本链与摘要复验，拒绝当前/未来日期及不平证据。全局幂等键绑定操作者、日期、原因；审计和 Outbox 同事务回滚。
- 新增事故发现、确认、不同人员结案、复发、服务端消除证据及 P0 五分钟升级；部分扫描不得清除已有异常。处置不解除钱包暂停、不改资金分录。
- 最近登录核对服务端刷新令牌族创建时间；刷新不延长有效期。生产操作写入 503，真实登录身份、财务权限、版本和幂等键均由服务端检查。
- Worker 注册独立监控和 Sandbox 回执。修复函数 `.run_once` 启动错误及相同任务名共用调度时间的问题。监控检查不平账本、损坏证据、未知提现、储备、孤儿订单、暂停、失败/延迟告警，成功扫描心跳超过 120 秒判过期。
- 完整监控扫描互斥：PostgreSQL 会话锁、文件 SQLite 操作系统锁、内存 SQLite 引擎线程锁。忙碌扫描不读取来源、不清除事故、不更新心跳。进程终止释放锁；PostgreSQL 单连接来源池亦可运行。
- 0041 仅增五张运行表；隔离 PostgreSQL 验证旧数据与模式约束保留，降级明确拒绝删除证据。OpenAPI 同步新增七条操作路径。

已生成实际服务运行的 [合成流程样例](artifacts/2026-09-06/wallet-operations/sample-operations.json)，可通过同目录 `sample_operations.py` 重跑：封存 → 储备不足发现 → 财务确认 → 模拟储备补足 → 不同人员复核 → 重复投递去重。样例明确 `SYNTHETIC_LOCAL_SANDBOX`，结案后 `wallet_still_paused=true`。

## 测试记录

测试先于新增实现运行：日结/事故/监控模块不存在时失败；新登录辅助函数缺失时两项失败；新接口未挂载时四项 404；Worker 五项失败包含实际启动 AttributeError。领域审阅进一步复现同名调度缺失、FAILED 告警不可见、交错扫描覆盖问题，并增加回归后修复。事故部分扫描参数缺失也先出现预期 TypeError。这些初始运行在任务工具历史中可追溯，最近登录 red 文件保存在 artifacts。

- 日结与报表 SQLite/PostgreSQL：50 通过，包括并发版本、跨操作者键冲突、补录、篡改、审计/Outbox 整体回滚。
- 事故 SQLite/PostgreSQL：21 通过，1 项 SQLite 不适用并发测试跳过；PostgreSQL 实际执行并发发现/确认/回执测试。
- 0041 与迁移头：11 通过，包含隔离 PostgreSQL 新 DDL 验证。
- 监控互斥与监控：14 通过，1 项内存 SQLite 跨进程测试按范围跳过；文件 SQLite 与 PostgreSQL 跨进程锁实际执行。
- 综合专项：[focused-tests.txt](artifacts/2026-09-06/wallet-operations/focused-tests.txt)，91 通过、1 跳过，含真实刷新会话门禁、新接口、全部 Worker、告警回执写入后确认丢失/重启重领，以及连续失败进入 DEAD。监控锁专项另列如上。

最终 `scripts/verify.ps1` **PASS**：合计 **571 通过、24 跳过**，其中业务 API/Worker 452 通过、24 跳过，Flutter 边界 65 通过。OpenAPI、UI 契约、AST、Alembic 单一头/离线生成、Compose 均通过，见 [repository-verify.txt](artifacts/2026-09-06/wallet-operations/repository-verify.txt)。PostgreSQL 环境门禁测试已另行执行，如上述专项；内存 SQLite 跨进程项目明确不适用。该离线生成不代表完整历史迁移已在线执行成功。

领域复审 PASS 后，Quality/Security 审阅 PASS，均限定本轮 Sandbox 范围，见 [reviews.md](artifacts/2026-09-06/wallet-operations/reviews.md)。本轮实现文件与新增测试 Ruff 通过；调度测试两处 lambda 风格问题改成函数后六项回归通过。OpenAPI 再次独立核对通过，合成样例在最终扫描锁实现上重跑通过，`git diff --check` 通过。依赖原有 Starlette/httpx、Pydantic 弃用提示不属于本轮新增缺陷；未忽略新的测试失败。

## 结论边界

这不是生产资金功能全量验收：没有真实 MPC、独立链证明、外部告警投递 SLA、独立 WORM、跨故障域 RPO=0、灾备与 iOS 真机证明。完整历史数据库升级仍受既有 0025 重复添加 `moments_preferences.cover_url` 阻塞。日报最多捕获 100,000 条证据，超限拒绝，未提供大账本离线导出。运行数据库和哈希不能抵御拥有数据库管理权限者同时篡改原文与摘要。须由独立基础设施检测 Worker 整体停机；同一 Worker 不能自证真实通知送达。

操作步骤及恢复边界见 [运行手册](../runbooks/wallet-operations.md)。
