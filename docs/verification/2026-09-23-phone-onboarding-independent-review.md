# 2026-09-23 手机自动开通独立规格与安全复核

范围：detached support-feedback-20260923 工作树，基础7140ace2。审查者未修改phone实现；先规格、后安全。依据用户要求：新手机号需邀请码，不降低短信限频/封禁/条款/双域会话边界。审查时间2026-09-23，精确主动耗时未计。

## 规格结论

- 未知手机号仅在OTP证明有效后，携邀请码与terms_accepted创建账号；原有ACTIVE登录仍返回原200会话形状，无需新字段。
- 新账号安全随机密码，公开handle为服务端HMAC派生，不含全号；昵称仅尾4位；无伪邮箱。
- Matrix仍通过既有Outbox开通，等待期202票据不是会话。完成票据后继续既有业务/Matrix双域流程，不修改E2EE材料。
- 最终补充on_new_account回调仅新账号路径使用原auth:register:v2 IP/device桶3/hour；原phone登录10/hour、SMS IP3/10min及按号码限流继续保留。回调位于OTP成功事务提交前，429回滚用户/邀请码使用/OTP消费，不产生半成品账号。新增test_existing_registration_rate_gate_rolls_back_all_signup_state覆盖。

## 安全发现与最终处置

### P1 待验证预注册凭证劫持（已修）

初版login将PENDING_PHONE凭login OTP提升，继承原预注册password_hash。独立SQLite探针证实：预注册→手机OTP自动开通后status=PENDING_MATRIX，pre_registration_password_still_valid=True。探针逻辑完成，临时DB退出清理遇Windows文件占用，整条shell exit1，不记为测试通过；未发生生产请求。

最终按root裁决：PENDING_PHONE明确返回PHONE_REGISTRATION_INCOMPLETE409，必须走原registration_session验证，不继承/更改其密码、用户名或邀请码关系，不创建resume ticket/Matrix Outbox。攻击回归测试已由实现agent添加并通过，审查已读最终源码。

### P2 页面退出后排队会话写入缺少检查（已修）

初版shouldContinue仅在_writeCurrentSession入队前检查，等待前序写入时页面可失效。最终在实际入队action执行时再次检查；GatedStore阻塞前次真实存储操作、第二次排队后取消的测试证明新账号不会覆盖旧会话。HTTP迟到ACTIVE/PENDING和有限轮询亦有测试。

## 最终边界核对

OTP行锁+条件消费保留；错误尝试预算保留。resume ticket随机高熵、服务端只保存HMAC，5分钟过期、设备摘要绑定、单次消费，当前手机号摘要/phone_verified_at校验防换绑后继续兑换。锁定/撤销/过期/改号拒绝；TokenService签发前复查ACTIVE。号码请求对不存在与可登录账号均accepted，无新增公开存在性查询。

ticket消费与TokenService发会话分事务，失败需新OTP；本行为已由root明确接受，不宣称兑换幂等。shouldContinue覆盖新增HTTP/poll及排队写入阶段，未声称原有后续Matrix链任意阶段取消均已覆盖。

## 验证与限制

独立执行test_phone_onboarding.py：10 passed in2.69s（当时最终限流回调尚未加入；同shell后续rg无匹配导致wrapper exit1，不能记整个shell通过）。最后限流变更只读复核源码和新测试；复用实现agent最终PG+onboarding12通过、Flutter23通过证据，见2026-09-23-phone-onboarding.md。未重复根的冻结全量。

最终未发现新增阻断项。API/OpenAPI整合、冻结全量、真实设备与生产发布由root负责；本审查不等于已部署或真机验收。
