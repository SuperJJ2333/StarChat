# 客服异步充值提现与后台开通

- 用户授权：归档删除其他多余分支，仅保留main；充值/提现两步UI、同款数字键盘、说明小字、任意客服独占处理、到账后才发点钻、两小时时限、后台客服开通/登录及订单消息提醒。
- 用户已确认：超过两小时未完成进入待核对策略。
- 基线main14b57d45，真机2159；此为开始时版本，本批实现已完成，未部署。
- 当前：分支归档完成，用户已批准设计，本地实现与隔离验证已完成。
- 所有权：本任务设计/计划/ADR、后续recharge/manual_wallet/identity与相应Flutter/HTML页面；当前有产品代码修改；文件分工见实施计划。
- 设计：docs/superpowers/specs/2026-09-23-support-order-workflow-design.md。
- 分支证据：artifacts/2026-09-23/support-order-workflow/branch-archive/；10个分支归档ref已核对，脏树快照ZIP CRC和SHA256通过，切换detached前后status一致；本地仅main。
- 下一步：后续按发布运行说明准备配套后端与客户端交付；本批不执行部署/安装。
- 计时：工具结果保留，未记录起始完整时刻，不估算总耗时。

| 验收ID | 要求 | 状态 |
|---|---|---|
| GIT | 本地仅main且所有旧工作可恢复 | 完成 |
| DEP | 充值两步、官方钱包、先到账后入账、2小时核对 | 本地完成、未发布 |
| PAY | 提现两步、认领、真实付款确认、超时核对 | 本地完成、未发布 |
| UI | 金额键盘复用、结算说明小字 | 本地完成、未发布 |
| AUTH | 绑定既有APP客服身份，邮箱/手机号验证码开通 | 本地完成、未发布 |
| ADMIN | 公共队列、独占处理、消息提醒、恢复审计 | 本地完成、未发布 |

- 实施计划：docs/superpowers/plans/2026-09-23-support-order-workflow.md。
- ADR：docs/adr/0081-support-order-settlement-and-staff-activation.md。
- 用户最新确认：参考汇率估算金额优先展示，实际到账以客服结算为准。
- 隔离PostgreSQL 16.9：0001→0087迁移已通过；并发/凭证测试继续。未发布生产、未发送真实验证码、未发生真实充值/出款。

## 整合门禁检查点

- 实现与独立规格/质量安全复审已完成；源码冻结，当前全部未提交在 main。
- Flutter全量3875通过；后续帮助文案修改后钱包126通过；全项目analyze最终0 issue；frontend265通过。
- API整合7通过；财务PG与恢复专项20；真实PG资金触发器、独立进程认领/OTP、通知乱序均通过。最终schema0087含review_authorized_at，新库迁移+pg_dump/restore已复验。
- 首轮verify因旧admin fixture缺客服开通前提中止；仅fixture通过正常OTP开通，不放宽运行时。admin/support/groups132通过。
- 第二轮完整verify最终exit 0（2026-09-23 05:00 UTC）；API/worker2616 passed /65 skipped，mobile108 passed /1 skipped，Infra144、Getui28、Bot9。UI契约、import/AST、单head0087迁移、OpenAPI和Compose均PASS。完整日志verify-final.log及verify-final-exit.txt保留；--maxfail=1未跳过任何测试。
- 完整后端耗时1551.47秒，mobile边界443.30秒；第三方弃用提示已在整合报告说明，不过滤告警。未执行项不推断通过。
- 整合报告 docs/verification/2026-09-23-support-order-workflow.md；最终逐文件SHA清单 implementation-inputs.json；源码身份为包含本记录的main提交。
- 下一步：依 docs/runbooks/support-order-workflow.md 准备配套发布与新包验收。本批没有生产部署、APK安装、真实短信或资金操作。
