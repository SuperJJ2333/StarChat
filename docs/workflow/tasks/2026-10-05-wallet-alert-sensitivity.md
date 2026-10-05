# 钱包告警原因、敏感度与管理员暂停边界

## 恢复入口

- 用户授权：2026-10-05 用户要求三项修改：异常告警不得自动暂停钱包；邮件解释具体问题和起因；降低 MANUAL_SOURCE_UNHEALTHY 对简单网络问题的敏感度。事件 ec3d15d3-ca19-47f8-b7ae-fc61d7635066。
- 状态：用户明确“同意这套阈值和邮件方案”；A1–A3 已实施、评审、生产发布及验收。
- 工作区：D:/pythonProject/outsource/StarChat，源码基线 4c8c16c7。既有下载页、current-state 和历史验证文件删除等变更保留；没有领取这些文件。
- 本任务拟拥有：manual_reserve_monitor.py、funding_source.py、incidents.py、alert_delivery.py、wallet_alert_email.py、email_sender.py、对应告警/观察/监控测试、必要的非财务诊断状态扩展及本任务文档。具体实施时先冻结文件哈希、确认工作区隔离。
- 既有批准政策：[9 月 30 日监控邮件计划](../../superpowers/plans/2026-09-30-wallet-monitor-email-only.md)、[ADR](../../adr/2026-09-30-wallet-alert-only-and-unbroadcast-void.md)。不重新申请取消自动暂停的权限。
- 新方案：[已批准实施方案](../../superpowers/plans/2026-10-05-wallet-alert-sensitivity.md)。隔离工作区 C:/Users/Administrator/.codex/worktrees/wallet-alert-sensitivity/StarChat，分支 codex/wallet-alert-sensitivity。
- 更新时间：2026-10-05 20:20 +08；调查开始准确时刻未知。
- 下一步：按既有业务流程处理后续实际告警；本任务无待执行发布操作，不新增自动化、不发送测试邮件。源码与验收记录保存在任务分支，主区其他工作保留。

## 验收台账

| ID | 预期 | 已确认事实 | 实现/验证/生产缺口 |
| --- | --- | --- | --- |
| A1 | 告警无全局自动暂停，只有管理员手动控制 | 监控及手动权限回归、隔离 PG 和生产控制读回通过；暂停 false、原因 null | 已发布；未执行暂停/恢复或财务写入 |
| A2 | 邮件说明实际原因与起因 | 不可变、脱敏诊断；中文原因/首次原因/时长/影响/建议/北京时间；真实事件缺原因不猜测网络 | 已发布；最终 worker 隔离 SMTP 捕获与重复投递去重通过 |
| A3 | 短暂故障降噪，严重故障即时通知 | 持久连续 600 秒、三次不同有效观察恢复、并发去重、新严重原因一次通知、重启保留状态 | 已发布；P1 保留，既有精确预算超时 T2 保留；不放宽资金证据 |

## 生产证据

- 事件发出：2026-10-05 00:00:27.530309 +08，类型 wallet.incident.reopened，P1；00:00:29.513720 +08 投递为 PUBLISHED，attempt_count=1。
- 事故：3f86ae92-038c-4816-b40d-b92a887bbb6e，第 15 代；调查时 RESOLVED、condition_active=false。事故 cleared_at 是后续业务复核时刻，不等于数据源首次恢复时刻。
- 同窗口观察：runs 73658–73670 为 OK、error_code=null；observations 73033–73036 stable_balance=0 / RECONCILIATION_UNVERIFIED，73037 stable_balance=1 / RECONCILIATION_UNVERIFIED，73038 起 stable_balance=1 / SOURCE_MATCHED。73038 heartbeat 为 2026-10-05 00:00:57.833 +08。
- 结论边界：能证明采样不稳定与尚未对账，不能证明其底层一定是网络访问故障。源码需要连续两次可比较的稳定快照才能得到 SOURCE_MATCHED。旧容器已于 2026-10-05 05:02:24 +08 重建，本次 docker logs 时间窗未返回结构化记录，不用缺失日志编造 RPC 错误。
- 当前镜像观察：API 03c5647de574，worker 7146c7234589；schema 0094_support_finance_order_recovery。worker 实际导入 /usr/local/lib/python3.12/site-packages/app/modules/wallet/manual_reserve_monitor.py，不能仅覆盖源码目录。
- 脱敏证据：[事件](../../verification/artifacts/2026-10-05/wallet-alerts/incident-evidence.json)、[观察及控制](../../verification/artifacts/2026-10-05/wallet-alerts/source-evidence.jsonl)。没有导出钱包地址、余额、SMTP 凭据或用户信息。

## 阶段计时与限制

- 调查结束检查点 18:40:43 +08；各只读查询秒数见会话工具输出；开始准确时刻未记录，不推算精确总耗时。
- 首次探针在 /tmp 运行缺 worker integrations 导入路径，显式设置容器现有 PYTHONPATH 后完成查询；首次 control 查询使用不存在的 control_epoch，被 savepoint 隔离，随后按真实列修正并读回。
- 18:44 起用户批准后隔离实施，专项先红后绿；19:40–19:55 全量四分片回归（最长 904.89 秒），3918 通过、128 条件跳过、4 旧契约失败随后修正。最终钱包/邮件回归 1265 通过、31 条件跳过、1 既有弃用警告，189.41 秒。源码修改后的专项回归覆盖受影响输入，未重复无关长测试。
- 19:55–20:09 最终镜像、PG 恢复/并发及回退演练检查点；候选和回退协议门禁均通过。演练修正了 /tmp Python 脚本导入路径和事故时间线/告警 topic 选择；watch render 从实际 inspect 补齐既有插值参数，并比对 env、挂载及资源。
- 20:09–20:17 生产迁移、清单服务切换、公网与运维验收检查点。后置 env 比对改为含未赋值键的映射比较，避免列表排序误报；没有重复迁移/切换。评审建议的 proof 成功/角色/digest 校验已加入并只读复核通过。
- verify 已执行：仓库、部署、模板门禁通过，render 因本地缺 .env 受阻；ruff 未安装。没有复制生产秘密补环境，也没有宣称完整 verify 或 lint 通过。OpenAPI 无变化检查、专项/迁移/协议门禁与真实 PG 检查通过。
- 规格、领域及质量/安全独立审查通过；最终脚本及兼容回退复审通过。本任务隔离 PG 容器/卷/网络和临时 SOCKS 已清理；服务器私有备份保留。详见[验证报告](../../verification/2026-10-05-wallet-alert-sensitivity.md)。
