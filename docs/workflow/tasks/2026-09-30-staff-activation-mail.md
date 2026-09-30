# 首次开通邮箱投递修复

## 恢复入口

- 用户报告首次开通邮箱收不到，授权发送效果测试；随后将邮箱更正为 `137***@163.com`，并确认15:33测试邮件进入收件箱。测试信明确不用于开通，没有创建有效挑战或调整账号角色。
- 关联批准设计：[ADR-0083](../../adr/0083-staff-console-session-access.md)、[客服计划 A2](../../superpowers/plans/2026-09-23-staff-console.md)。本次同步既有生产 API 实现到 worker；不新增认证策略。
- 工作树：`codex/wallet-alert-only-payout-void`，本任务仅拥有 shared identity/staff_activation.py、对应测试及本记录。钱包订单撤销与恢复仍是另一任务的待办。
- 状态：worker修复已发布；正式开通邮件已重新申请，待用户确认收件。
- 最新检查点：2026-09-30 15:45 +08。下一步收到正式邮件反馈后核对开通结果，不要求用户发送密码或验证码到聊天。

## 需求与根因

| ID | 预期 | 证据 | 状态 |
| --- | --- | --- | --- |
| E1 | 首次开通邮件正常投递 | API使用staff-identity-v2，旧worker使用v1；新测试复现handler静默跳过 | 已修复发布 |
| E2 | 指定测试邮箱收件 | 15:33真实SMTP投递测试、用户确认收件箱收到 | 已确认 |
| E3 | 正式开通邮件 | 15:45:18新请求投递任务3.12s处理，v2身份一致，无错误 | 待用户收件确认 |

- 首次15:30测试发送到用户最初给出的带a地址；用户更正后15:33发到正确地址，用户确认收件。测试标识末尾bc11，只证明投递通道和模板，不伪造真实开通。
- 生产API模块sha256 `4b5ebc44ee252d7bba721301c4065f7d44aba57ece52aa1d3b8fb028b2630703`；旧worker安装包app中的模块仍v1。API产生v2身份摘要，worker require_pending_delivery拒绝并被邮件handler吞为安全跳过，Outbox仍PUBLISHED。生产测试邮箱挑战读回v2一致、v1不一致，证据不输出身份、邮箱原文、地址或验证码。
- 最小修复：同步实际生产API该模块到worker两副本，所有身份、联系方式、角色、过期/消费校验保留。没有变更API、数据库、凭证、角色或金融状态。

## 验证与发布

- 红：API-v2快照送真实worker handler，发送数0，pytest1 failed/25 deselected、2.40s。绿：客服身份与SMTP sender36 passed、20.21s；worker identity5 passed、0.71s。Windows/pwsh7，Python3.12虚拟环境，PYTHONPATH business-api与worker/app，UTF8。日志位于 `docs/verification/artifacts/2026-09-30/staff-mail-{red,green,worker}.log`。
- verify.ps1实际执行：repository/deployment/template PASS；配置渲染因隔离树缺.env退出1，没有导入生产秘密。详见staff-mail-verify.log，未声称完整verify通过。
- 规格/领域先PASS，质量/安全后PASS。候选API/worker双角色续期协议预检查及实际发布门禁PASS；首次错误使用check --compose而未指定镜像返回失败，改用实际双角色image参数，不绕过门禁。
- 2026-09-30 15:43:59 +08仅worker切换至 `sha256:00c0e10972c97f18d5aae435032da642ad2a7752265dd66cfe4712ec3268c5b7`，healthy/0 restart；API保持902eaefc，其余30容器不变；两worker运行副本hash与API一致。HTTPS/API ready。私有配置0700目录/0600文件留服务器，不回传秘密。
- 源码仅更新一个共享模块，41项专项加角色镜像门禁覆盖变化，未重复未受影响的移动构建和30分钟钱包全量。
- 证据：staff-mail-corrected-probe.json、staff-mail-events-after.json、staff-mail-images.json、staff-mail-deployment-proof.json。15:45正式请求比发布晚，历史过期挑战不自动重放。

## 计时与回退

- 调查起始精确时刻未记录；SMTP两次15:30/15:33，测试自身时间如上，15:43:59切换，15:45检查；不估算精确主动时长。
- `/opt/starchat/releases/staff-mail-20260930/`保留候选/旧worker回退配置和镜像；当前受控配置 `/opt/starchat/releases/guarded-xocl5j_i/compose.json`。旧worker90d7回退保留金融修复与续期协议，但会恢复此次邮箱故障，只有候选发生其他回归才使用。
- 下次恢复先核实际API/worker镜像、模块hash、新OTP事件时间与用户收件结果；PUBLISHED不单独作为收件箱证据。
