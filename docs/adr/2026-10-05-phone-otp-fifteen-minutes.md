# ADR：全部手机短信 OTP 统一15分钟

日期：2026-10-05。状态：**root独立领域/规格审查ACCEPT；允许实施，质量/安全及源码候选审查另行执行**。

依据用户本轮明确要求与[批准计划](../superpowers/plans/2026-10-05-global-search-otp.md)O1，仅替代ADR-0075/0085中手机短信验证码5分钟及旧阿里云1–10分钟限制。邮箱期限按既有用途保持：注册邮箱10分钟，PhoneOtpService邮箱用途5分钟；邀请续行、登录恢复、换绑会话、改密恢复证明继续既有5分钟，不把共享常量全局改900。

## 决策

1. 对 PhoneOtpService 的全部 SMS_PURPOSES：registration、login、phone_rebind_old、phone_rebind_new、staff_activation_phone、password_reset_phone、email_bind_old_phone，签发时本地挑战expires_at = created_at +900秒。队列发码和同步发码使用相同按用途期限选择；验证必须在expires_at之前，14:59可用、15:00及之后拒绝。已签发挑战保留其原expires_at，不回填延长旧码。
2. EMAIL_PURPOSES仍300秒；login_invitation/login_resume、PhoneRebindSession及密码恢复证明仍原期限。用户验证手机码后产生证明的期限从证明签发计时，不能误用15分钟短信期限。
3. 本轮手机号服务固定15分钟。阿里云adapter默认15，Settings默认15；显式非15配置拒绝装配以避免本地900秒与供应商5/10分钟分裂。SendSmsVerifyCode请求ValidTime=900，模板min="15"，不请求返回明文验证码。API和Worker共用build_sms_transport及相同配置，Compose/示例默认同步15。root生产增量显式更新两角色配置，先冻结现有配置/镜像并验证候选及兼容回退；本ADR不授权此worker生产操作。
4. [阿里云官方SendSmsVerifyCode契约](https://help.aliyun.com/en/pnvs/developer-reference/api-dypnsapi-2017-05-25-sendsmsverifycode)2026-10-05核对：ValidTime单位秒，默认300；页面未列10分钟上限。模板min为显示变量，不代替ValidTime。此证据支持发送900参数，不冒充真实短信收发已验收；测试只使用供应商替身。
5. 五次尝试、同目标10分钟≤3/小时≤5、60秒客户端冷却、IP限流、用途/目标/当前用户/registration session绑定、原子单次消费、防枚举、供应商失败不扣次数/不消费、deadline后重新核对当前UTC及事务Outbox/投递状态保持。长有效期不增加次数，不扩大恢复或E2EE权限；不改金融、refresh/RBAC/TOTP、Matrix或密钥状态。

## 验证与回退

按任务批准的TDD先执行失败测试：所有SMS用途同步签发14:59通过/15:00拒绝、队列password_reset_phone期限900；EMAIL用途仍300；供应商参数900/min15、API/Worker默认/装配一致、非15配置failclosed。复用/运行相关尝试、绑定、重放、供应商异常和证明期限回归；隔离SQLite提供服务行为证据，不声称真实PostgreSQL锁竞争或短信投递。任何PG专门门禁由root决定执行，不导入生产秘密。

无需数据库迁移、OpenAPI字段变化或旧挑战更新；滚动切换前既有挑战按数据库expires_at验证。回退成套还原旧镜像及其5分钟配置，新签发后回退仍可能提前拒绝供应商旧码，明确要求重新取码；不延长/重签已签发挑战来伪造兼容。独立domain/spec审查后再quality/security审查，具体源码候选审查及root生产冻结/gates独立于本ADR设计接受。

文件所有权：此worker owns ADR draft、phone.py、sms_aliyun.py、core/config.py、聚焦Python/infra测试及必要SMS配置默认；不编辑mobile、workflow、版本、root发布脚本或真实server配置。root可审查/追加ADR状态；通过前不改可执行代码。
