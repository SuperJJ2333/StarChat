# 第三轮待核对流程复审任务记录

## 恢复入口

- 用户授权：检查 ZCode 第三轮修改是否正确，及时纠正。仅本地实现、隔离测试；不含生产、真实资金或短信。
- 批准计划：docs/superpowers/plans/2026-09-21-pricing-auth-redpacket-group-program.md；ADR-0077/0079 第三轮补充。
- 负责人：根任务；充值服务与专属测试由 recharge_second_review，群协调与专属测试由 sms_second_review。根任务拥有 API、registry、网关生命周期、前端、真实 Synapse 测试及文档；文件不并发编辑。
- 工作树 `.worktrees/review-flows-audit`，分支 `codex/review-flows-audit-20260922`。主工作区 129 个相关输入已快照，HEAD/hash 见工件 input-snapshot.json。
- 当前状态：专项、真实依赖隔离验证及完整 verify 通过（后端 2440/58，exit 0）；按哈希回填主工作区，未发布。
- 下一条操作：继续后续客户端/工作台交付；复用本轮同输入证据，真实短信和生产启用仍待对应条件。

## 验收台账

| ID | 预期 | 本轮证据 | 发布/未验证 |
| --- | --- | --- | --- |
| R-MONEY | 证据不足不释放、幂等不误操作新绑定、身份原样 | 44 充值回归 + PG 四项 | 未发布，无真实资金 |
| R-GROUP | 正向确认可完成，未知发送不释放，终态不复活 | 59 模块/21 最终回归、真实 Synapse 丢返回测试 | flag 关闭；生产/外部竞态待验 |
| R-AUTH | ACTIVE/系统管理员及关闭开关不可绕过 | API 回归/独立只读复审 | 无权限弱化 |
| R-UI | 真实 API 已接线，错误不显示为空，分页防过期响应 | 235 前端 + 真实 DOM fixture | 全栈/完整视觉/历史详情页未验收 |
| R-EVIDENCE | 取消占位联测，完整 ACL 比对及实际旧群主拒绝 | 2 项真实 Synapse +2 desync/4API 共 8 passed | 不代替容量、短信或真机 |
| R-GATE | 最终源码完整门禁通过 | PASS，exit 0；后端 2440 passed/58 skipped | skips 继续未验证 |

## 版本、计时及证据

见[复审报告](../../verification/2026-09-22-review-flows-code-review.md)。完整日志与源码身份位于 docs/verification/artifacts/2026-09-22/review-flows-audit/；本地运行，无 CI run ID。初始失败及夹具修正记录均保留。

| 阶段 | 时间（2026-09-22，+08:00） | 说明 |
| --- | --- | --- |
| 快照/审查 | 以 input-snapshot.json 为准 | 早期逐条读取精确耗时未记录 |
| TDD/独立复审 | 快照后至 12:11 前 | 各 pytest 日志计时，不把并行耗时相加 |
| 真实 Synapse/PG/浏览器 | 专项与完整门禁期间 | Synapse 8 项组合 75.88 秒；PG 有真实锁等待；HTTP fixture 单独证据 |
| 完整 verify | 约 12:11 起，12:42 已完成并核对 | verify-full.log / verify-exit.txt |
| 回填 | 按哈希回填 | applied-changes.json 精确时间 |

## 交接与回退

- 迁移保持 0081，依赖锁不变；既有迁移/SDK 构建证据可按输入哈希复用。
- 新复核接口必须 binding_id 和 Idempotency-Key；失去财务记录不是释放依据，未知 Matrix 发送不是未发送证据。
- PostgreSQL 容器 starchat-review-flows-pg 已停止并自动删除；真实 Synapse 夹具自行 finally 清理本次创建的容器/密钥目录。其他任务遗留容器未动。
- 无生产变更、未提交；回填前检查哈希，不覆盖其他任务。下一阶段继续 Flutter/工作台与真实短信授权验收，不重复实施本轮修正。
