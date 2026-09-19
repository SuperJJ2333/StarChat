# ADR-0074：注册邮箱验证完成前允许更换邮箱（BUG-12）

日期：2026-09-19　状态：已批准（用户会话内明确批准，D4 决策）
关联：docs/畅聊缺陷清单-0917-标准化.csv BUG-12；docs/superpowers/plans/2026-09-19-defect-batch-0917-fix-plan.md

## 背景

注册流程中邮箱在创建会话时即绑定：注册页「修改邮箱」只是退回上一步，重发验证码仍发往旧邮箱，新邮箱被静默丢弃——用户永远无法在验证前纠正邮箱（BUG-12，严重级）。服务端此前不存在任何更换邮箱通路。

## 决策

1. **边界（D4）**：邮箱**验证完成前**允许随时更换；更换时作废旧验证挑战、更新账号邮箱、新验证码发往新邮箱，`registration_session` 保持不变（客户端无感）。**邮箱验证通过后**（账号离开 `PENDING_EMAIL`）不再支持在注册流程内换邮箱，后续走"账号设置 → 换绑邮箱"（另行立项）。
2. **端点**：`POST /api/v1/auth/registrations/{registration_session}/email`（202），Body `{email}`，要求 Idempotency-Key；限频 10 次/小时/设备。
3. **语义**：邮箱已被其他账号占用 → 409 `EMAIL_ALREADY_REGISTERED`；会话无效或账号已离开 PENDING_EMAIL → `EMAIL_VERIFICATION_INVALID`。审计事件 `identity.email.changed`。
4. **保护变更说明**：本变更触及认证/注册流（AGENTS.md 受保护变更清单）。产品决策（D4 边界）由用户书面批准；安全面评估：换邮箱仅限未验证账号、需持有有效 registration_session（32 字节随机）、限频+幂等键、新码只发新邮箱、邮箱唯一性校验防占用。领域/质量安全评审随本批次代码评审执行。

## 实现

- 服务端：`EmailVerificationService.change_email`（registration.py，结构仿 resend）；端点 identity.py。
- 客户端：`RegistrationGateway.changeRegistrationEmail` + business_api_client 实现 + RegistrationController.changeEmail + 验证页「修改邮箱」改为原地弹窗输入新邮箱（不再退回注册页），成功/失败均 toast。
- 测试：服务端 `test_registration_email_change.py`（换绑+新码可验证 / 邮箱占用 409 / 已验证拒绝）；客户端 registration_controller 用例（成功更新冷却、409 提示）。

## 后果

- 未验证注册的邮箱纠正不再需要人工介入。
- 旧邮箱收到的验证码随旧挑战作废而失效；同一邮箱可被同一用户反复更换（限频约束）。
- 已验证账号的换绑邮箱为独立后续功能，不在本 ADR 范围。
