# 账号联系方式与验证码改密运维

依据 [ADR-0085](../adr/0085-account-credentials-and-otp-password-recovery.md)。本记录说明部署前配置和验收；本轮仅完成源码与隔离验证，未修改生产配置或发送真实验证码。

## API 与 worker 配置一致性

新验证码由业务 API 原子写入挑战与 Outbox，worker 投递。两个服务必须使用同一个 `BUSINESS_EMAIL_VERIFICATION_SECRET` 与 `BUSINESS_OTP_HASH_SECRET`，并接收相同的手机开关和阿里云配置。密钥仅在服务器受控环境中配置，不写入仓库、命令输出或验收日志。

- `.env.example` 默认 `BUSINESS_PHONE_AUTH_ENABLED=false`、`BUSINESS_SMS_PROVIDER=disabled`，短信凭据和 OTP 哈希密钥为空。
- 生产开启手机号功能时，需要 `BUSINESS_SMS_PROVIDER=aliyun_dypns`、强随机 `BUSINESS_OTP_HASH_SECRET`、有效的 access key、签名和模板；生产配置验证继续拒绝不完整或不合规设置。
- `BUSINESS_SMS_ALIYUN_REGION` 默认 `ap-southeast-1`，`BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES` 默认5。更改必须同时应用于 API 与 worker，并保持服务端验证码有效期一致。
- 邮箱通道沿用 worker 的 `SMTP_DELIVERY_ENABLED`、`SMTP_HOST`、`SMTP_PORT`、`SMTP_SECURITY`、发件人及凭据。生产需要远端 SMTP 和 TLS；关闭投递时不能把挑战标记为就绪。
- 此变更没有新增数据库迁移；旧邮件链接恢复与旧手机号协议继续兼容。

## 投递与恢复语义

请求受理不等于投递成功。未知或未验证联系方式使用统一公开反馈；投递中的挑战不可验证。worker 单次领取挑战，再核对当前账号、绑定和验证快照；失败、过期、改绑和重放不能重新激活挑战。失败记录使用稳定脱敏错误，不含邮箱、手机号、验证码、密码或令牌。

验证码验证统一使用5秒响应窗口，执行预算4.5秒；迟到供应商结果或数据库锁等待不得扣次数、消费验证码或产生恢复证明。证明5分钟有效且单次消费。邮箱换绑的旧渠道证明从成功确认开始有效5分钟。

成功改密沿用 refresh family 撤销、24小时提现冷却、审计和同事务 Outbox。Matrix 聊天密钥及本地历史不作为账号恢复数据处理。

## 后续部署验收

实际部署仍执行 [移动交付流程](mobile-delivery-workflow.md) 与适用的生产发布流程。部署前检查两服务配置一致、SMTP/TLS 和短信签名模板可用，再以专用测试账号完成邮箱及手机号双渠道验收；真实发送和真实账号写入须具有对应授权。日志只记录脱敏结果、挑战状态、时间和证据身份。

源码门禁包含 `tests/infra/test_account_credentials_sms_worker_config.py` 和 Compose render；业务测试包含投递失败、重放、绑定变更、超时、并发及敏感信息泄露断言。最终源码验证结果记录在 [正式实施报告](../verification/2026-09-26-account-ui-implementation.md)。
