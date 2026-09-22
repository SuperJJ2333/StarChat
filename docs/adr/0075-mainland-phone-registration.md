# ADR-0075：中国大陆手机号注册、短信验证码登录与换绑

日期：2026-09-21。状态：**已批准（用户 2026-09-21 需求书中明确确认全部产品规则；本 ADR 记录技术决策与安全边界）**。授权范围：实现与隔离测试；不含生产发布与真实短信通道开通。

## 背景

现行注册为「用户名 + 邮箱 + 密码 + 邀请码 + 邮箱验证」（规格 §6.1、ADR-0074）。用户 2026-09-21 批准：支持中国大陆手机号**或**邮箱二选一注册；手机号注册必须短信验证；手机号登录使用短信验证码、不要求手机号密码登录；现有邮箱用户完全兼容；手机号支持完整号码搜索好友；换绑需先验旧凭证再验新凭证。本变更触及认证域（AGENTS.md 受保护变更清单），须领域与质量/安全审查。

## 决策

1. **手机号标准化与唯一性**：仅接受中国大陆手机号；输入允许 `+86`/`86` 前缀、空格/短横线，归一化为 `+86` + 11 位（`1[3-9]` 开头）后存储（`users.phone_normalized`）。部分唯一索引（仅非空行唯一）；`email_normalized` 同步改为可空 + 部分唯一，**禁止**用虚构邮箱占位。新增 `phone_verified_at`、隐私开关 `phone_findable`（默认开，用户可关）。
2. **注册通道**：`POST /auth/register` 新增 `channel: email|phone`。`phone` 通道：用户名 + 密码（≥12 位，规则不变）+ 邀请码 + 手机号 + 短信验证码；验证成功后进入既有 `PENDING_EMAIL→PENDING_MATRIX→ACTIVE` 状态机（手机通道对应 `PENDING_PHONE` 语义，复用同一 provision 编排）。稳定业务 user_id 与 Matrix 身份规则不变，不创建重复账户。原邀请码、封禁、设备/会话（单设备、60 天缓存、ADR-0062/0072）规则全部沿用。
3. **短信验证码（OTP）**：新 `otp_challenges` 表——`purpose`（`registration`/`login`/`phone_rebind_old`/`phone_rebind_new`/`email_rebind_old`）、目标（手机或邮箱）、归属 user/registration_session、`code_hash`、有效期 5 分钟、尝试次数上限 5、`consumed_at` 单次消费（条件更新原子置位，重放拒绝）。用途互斥：注册码不能登录，登录码不能换绑。发送限频：同目标 10 分钟 ≤3 条、1 小时 ≤5 条；IP 维度限流沿用全局限流器。**验证码登录只恢复登录权，不恢复 E2EE 历史密钥**——Matrix 设备密钥/本地加密存储边界（ADR-0063/0068 installation generation）不变，服务端不新增任何密钥恢复通道。
4. **登录**：`POST /auth/phone/login`（两步：请求码/提交码）。请求码对存在/不存在的手机号返回同一 202（防枚举）；提交码成功才签发既有 TokenService 会话。邮箱+密码登录路径零改动。
5. **换绑**（三步会话，服务端持有短时 rebind session，5 分钟）：
   - 已绑手机号 → 新手机号：必须先消费 `phone_rebind_old` 码（绑定 user+旧号），再消费 `phone_rebind_new` 码（绑定 user+新号）。
   - 未绑手机的邮箱账户 → 绑定手机号：先消费 `email_rebind_old` 码（发到当前邮箱），再消费 `phone_rebind_new` 码。
   - **"当前无手机号"≠"旧手机号收不到码"**：已绑手机账户一律要求旧号验证码，不提供邮箱验证降级绕过。
6. **手机号搜索**：`POST /contacts/search-phone`，仅完整号码精确匹配；目标 `phone_findable=false`、不存在、被封禁 → 同一空结果（防枚举）；命中返回公开资料卡（用户名/昵称/头像），**响应不含手机号**；按用户限流。
7. **短信供应商**：仓库当前无任何短信通道。定义 `SmsSender` 协议 + 生产装配校验；未配置时短信端点返回 `SMS_NOT_CONFIGURED`（fail closed，生产禁止固定验证码/伪发送成功）；测试注入录制型替身。真实供应商接入时实现该协议并在生产配置注册（`BUSINESS_SMS_PROVIDER` 等），密钥仅存服务端配置。
8. **日志红线**：不记录验证码、完整手机号（脱敏为 `+86****xxxx`）或认证令牌；OTP 表只存哈希。

## 迁移与兼容

- `0078_phone_accounts`：users 增列 + 部分唯一索引；email_normalized 改可空（expand，不回填、不改历史行）。纯加列，旧代码不受影响。
- 旧邮箱用户登录、密码找回（PasswordResetChallenge）不变；手机号不参与密码找回（找回仍走邮箱；无邮箱纯手机账户的找回通道**不在本 ADR 范围**，避免绕过原号码证明的恢复通道——由后续单独立项并明确用户决定）。

## 安全后果

- 手机号属 PII：唯一索引由归一化值承担；接口出参一律脱敏；审计不落完整号码。
- OTP 防重放/防爆破为认证安全门禁：尝试上限、单次消费、用途绑定、目标绑定缺一不可。
- 生产开启手机功能必须同时满足：`phone_auth_enabled=true` 且 SMS 供应商已配置（配置校验器强制），否则启动失败。


## 实施补充（2026-09-21，用户指定供应商）

1. **短信通道选型（用户决定）**：采用阿里云验证码短信 `dypnsapi 2017-05-25`（`alibabacloud_dypnsapi20170525==2.0.0`）：`SendSmsVerifyCode` 由**供应商生成验证码**（模板 `##code##` 占位符、`min` 有效分钟）并下发，`CheckSmsVerifyCode` 权威校验。适配器 `app/modules/identity/sms_aliyun.py`；`PhoneOtpService` 增加 `code_verifier` 注入路径——供应商校验替代本地哈希比较，尝试计数、用途/目标/会话绑定、单次消费等本地不变量全部保留；供应商不可达时事务回滚＝不计尝试、不消费。
2. **配置**：`BUSINESS_SMS_PROVIDER=aliyun_dypns` + `BUSINESS_SMS_ALIYUN_ACCESS_KEY_ID/SECRET`（SecretStr）+ SIGN_NAME/TEMPLATE_CODE/REGION/`_CODE_VALID_MINUTES`（1–10）；选择该通道但配置不完整即拒绝启动；生产 `phone_auth_enabled=true` 必须使用该通道且 `otp_hash_secret` 必填。凭据不进代码/日志/前端/测试快照；异常映射不含凭据或完整号码。
3. **依赖纪律**：SDK 在生产工厂内惰性导入，未安装即明确失败（`SMS_PROVIDER_UNAVAILABLE`）；测试以注入的 client/request 工厂替身运行，不做真实调用。真实通道开通与发送验收未完成，不得声称短信已上线。

## 第二轮复审修正（2026-09-22）

- 阿里云 `Code=OK` 只说明 API 调用成功；仅 `Model.VerifyResult=PASS` 且 `Model.OutId` 对应本地 challenge 才接受验证码。UNKNOWN/FAIL 计为错误尝试，供应商异常不消费验证码。依据：[CheckSmsVerifyCode 官方契约](https://help.aliyun.com/en/pnvs/developer-reference/api-dypnsapi-2017-05-25-checksmsverifycode)。
- Send/Check 使用一致、长度 20 的 SchemeName，由用途与 challenge 派生；OutId 使用 challenge 标识。不同用途、不同签发不能交叉验证。发送待确认时持久保留限频占位，但验证码不可验证；发送失败或已被新请求替代的 challenge 不得被迟到响应激活。
- 邮箱旧联系方式验证继续使用本地哈希，不能路由至短信供应商。SDK 2.0.0 使用中央 endpoint `dypnsapi.aliyuncs.com`，显式大陆国家码与六位数字验证码参数，不请求返回明文验证码。
- 已做替身行为测试和钉版 SDK 字段/endpoint 核对；动态 SchemeName 在真实账户中的可用性、短信签名模板与真实收发尚未验收，开启生产前必须验证。未做真实发送。
- SDK 及传递依赖同步进入 Docker 实际使用的 requirements.lock，保留其他既有版本；仅修改 pyproject 不足以通过镜像的 --no-deps / pip check。新增构建依赖一致性测试，隔离构建与生产工厂实例化不发送短信。


## 2026-09-22 短信实测后分类复审

沿用既有五次尝试、用途绑定、单次消费和供应商不可用不计次数规则。SDK 的 TeaException / ClientException 暴露结构化 code；只有精确 isv.ValidateFail（异常或响应体）判定权威不匹配。不得通过异常描述中的子串推断错码，否则网络/配置故障可能错误扣减用户次数。403/Forbidden 使用结构化 code/status 分类，错误文本不外传。没有改验证码有效期、登录/换绑协议、权限或生产开关。

独立领域及质量复审与离线 PhoneOtpService 集成验证：网络/配置错误保留次数，五次权威失败递减至零，第六次不再调用供应商。用户已确认真实短信验收完成；本轮不重复发送，Flutter 全链路另验。


## 2026-09-22 Flutter 手机契约复审

短信登录与密码登录一致，在新登录开始时清理旧 Matrix grant 冷却；避免旧会话 429 阻止新账号接入聊天。五个公开手机请求（注册、注册发码/验码、登录发码/登录）沿用客户端 8 秒网络预算，超时不自动重放、不接纳迟到登录结果。保持 epoch 和串行存储纪律、服务端限流、密钥边界与所有业务规则。

独立静态领域/安全复核确认 17 个方法与后端/OpenAPI 匹配；会话持久化、登出竞态、错误不改令牌、冷却与超时另有 Dart 实测。注册验码和充值取消的既有服务端不按客户端附带幂等键重放，UI 遇未知结果须查询注册/订单状态，不能将头字段存在当成端到端幂等。本次不修改该服务端协议。
