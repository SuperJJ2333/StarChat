# 手机登录与受邀自动注册专项验证

基线：detached 7140ace2，工作树 `.worktrees/support-feedback-20260923`。本域未提交、未生产部署、未真实发短信。

## 结果与契约

- 手机号允许+86/86、空格与既有分隔符归一化；合法11位实时启用绿色获取验证码。条款未勾选点击给明确提示且不发码。沿用共享AuthTextField/AuthAgreementRow、CupertinoButton及WeChatColors.brandPrimary。
- 未知手机号请求码会真实调用已配置sender替身；发码不开户。正确OTP+条款+有效邀请码后，同事务消费OTP、邀请码并创建PENDING_MATRIX用户、审计和Outbox。公开handle按既有秘密HMAC派生，昵称只展示尾4位；密码随机高熵，客户端不接收临时密码。
- `POST /auth/phone/login`新增可选invitation_code、terms_accepted；ACTIVE保持原200 tokens。新号/PENDING_MATRIX返回202 status/login_ticket/retry_after_seconds。注册限频沿用auth:register:v2的IP/device 3/hour，原SMS频率与verify限制保留。
- 新 `POST /auth/phone/login/complete` 接受login_ticket/device_key/device_name，开通中202、ACTIVE一次消费后200原会话。凭据32随机字节，数据库只存HMAC摘要；绑定设备、用户、当前已验证号码，5分钟过期。封禁/禁用/撤销/换绑/失效拒绝。票据不经过短信供应商校验。
- Flutter单次请求8秒；等待总60秒，每2秒查询。退出/后台/later epoch不接纳结果，会话写入队列执行时再次检查页面有效性。正常完成继续已有双域Matrix登录规则。此项取消保证针对新增HTTP等待与排队存储边界，不宣称重写全部既有Matrix生命周期。
- 既有PENDING_PHONE须携原registration_session走原注册验证；新login OTP明确409，不激活预注册者可能设置的密码/资料/邀请关系。
- ticket消费与TokenService签发仍分事务；故障安全关闭，交换回包丢失需重新登录，不声称该交换具备幂等，不自动重发OTP。没有新增迁移。

## red / green

- Flutter phone_ui_test：原实测有效号码按钮仍null（red）；修复后3通过。测试初期曾因worktree未pub get缺依赖、输入框焦点导致滚动布局尚未settle失败，均定位并修正测试装配；不是产品行为成功证据。pub get仅引起lock源标记漂移，已恢复原锁。
- `py -3.12 -m pytest tests/business_api/identity/test_phone_onboarding.py -q`：初始缺registration注入red2；新客户端注册字段用例初始缺invite body red1；新原注册限流guard初始缺callback red1。
- 服务相关phone auth/review/provision及新增onboarding+PG：40通过（增强前）；随后新增当前手机绑定/预注册攻击与注册限流回滚后，`test_phone_onboarding_postgres.py test_phone_onboarding.py`最终12通过，exit0，5.15秒。
- 隔离Postgres16.9容器端口先inspect确认loopback25486；每次随机phone_onboarding_前缀独立schema，8连接同时开户1胜7 OTP_INVALID，邀请只消费1次/Outbox1条；8连接同票兑换1胜7 LOGIN_TICKET_INVALID。测试结束仅移除自己随机schema，不访问生产。
- `flutter test --no-pub test/core/phone_onboarding_client_test.dart test/features/auth/phone_ui_test.dart test/features/auth/phone_login_controller_test.dart test/features/auth/phone_dual_domain_test.dart test/core/business_phone_review_test.dart`：23通过exit0。覆盖pending→Matrix完成→保存、晚到pending/ACTIVE拒收、真实占用存储队列后取消不保存新session。最后仅补pending超时可恢复消息；定点analyze之后无问题，完整最终Flutter门禁由root执行。
- 定点 `dart analyze` 所有变更auth/core与测试：No issues found，exit0。
- `node --test frontend/tests/phone-flows.test.mjs`：新增表单与实时按钮red2→green8，exit0。
- `py -3.12 scripts/verify_ui_contract.py`：PASS32组件/398页面，exit0。
- 曾有服务组合5失败为PYTHONPATH漏business-worker/app，补上后40通过；无对应代码绕过。

## UI与整合

Figma已退役：仅更新HTML demo `http://127.0.0.1:8153/index.html?screen=phone-login-phone-error` 对应catalog screen `phone-login-phone-error`（实际路由以demo app选择器为准）。registry新增2026-09-23-phone-onboarding，tokens/组件复用。HTML表单同样显示邀请码与同意提示、实时绿字。

原独立review发现的P1：PENDING_PHONE可继承预注册密码、队列lifetime未重查，均已修复；最终独立复核与完整verify/OpenAPI导出/所有平台检验由root整合记录。main.py无需改动，router内装配RegistrationService。主域钱包文件未由本agent改写；phone-flows.js/tests与registry先与钱包agent交接后编辑。

阶段时间：本子任务起始墙钟未采样（未知，不推断）。结束记录见下方；工具执行秒数以会话返回为准，不把并行耗时相加。下一步：root在冻结输入上完成全量门禁、独立终审、合入与授权发布。

## 输入身份

记录时间：2026-09-23T15:57:40.002929+08:00

- `services/business-api/app/api/identity.py` SHA256 `f6bb284c44ffb633819c63abbe6346dce084c4c15c7ca7f3702329aeea18892c`
- `services/business-api/app/modules/identity/phone.py` SHA256 `5765667d3b5c550f87c4343cf4b7a6cc5edadff6c401ae26c5f59c7917c672f3`
- `services/business-api/app/modules/identity/registration.py` SHA256 `5df9ad27792211e8157438619907c7a63a53a97f782935dd5dd6e25d072d4b05`
- `apps/mobile_flutter/lib/core/business_api_client.dart` SHA256 `c99e021c40f3900c8d4f6062706de24d02db89e25304cf47fed05463d53af531`
- `apps/mobile_flutter/lib/core/business_phone_contracts.dart` SHA256 `1cdf739d46e4d70c507e0dd27dbeb9f16720fc261403b425c82d6b4accbbe9d3`
- `apps/mobile_flutter/lib/features/auth/login_page.dart` SHA256 `321f92efde2083e5e99fa6168e7ebaefa40fca0f28c4f76b87d360eb46942c7f`
- `apps/mobile_flutter/lib/features/auth/login_controller.dart` SHA256 `96b18d28602010b0ee3af69cb833aed481a010b60ca9bbbd8d067cba78adc068`
- `apps/mobile_flutter/lib/features/auth/phone_login_controller.dart` SHA256 `3f8479a88ff79feeaa03bfac2d2f719d2ff053edbf606b1c0bc850d4fc6e044d`
- `apps/mobile_flutter/lib/features/auth/authentication_flow.dart` SHA256 `b536ed3de52d5d995a718ecacecc39f6e519e8241588fc2b57f5a6e10604098f`
- `tests/business_api/identity/test_phone_onboarding.py` SHA256 `ba63a545a15a80aa8348e93eb1729c22407b78bd3eecaffcf615523076a37776`
- `tests/business_api/identity/test_phone_onboarding_postgres.py` SHA256 `73ef9c96aa045aeea3fe30a05146e91c55d50c29af0f18256ea250c74746a32a`
- `apps/mobile_flutter/test/core/phone_onboarding_client_test.dart` SHA256 `2b81b7c7ca2f8d7eba68252d78f59d4c7cfd3e35643f511b43c719b152db4850`
- `apps/mobile_flutter/test/features/auth/phone_ui_test.dart` SHA256 `ab38f1b752f2d72d3c829fb02a316d34280c097604987bada7fd90076785ed10`
- 依赖锁 `apps/mobile_flutter/pubspec.lock` SHA256 `a2af1ef677f2bee3af4d012d15eb5dc2492d220bf66eabb27ccf62c17fd733fc`
- 依赖锁 `services/business-api/requirements.lock` SHA256 `bf7f8a5750ff01c14e0e4f74506d4b7246ab9c4bd1b7595400447c04ca4a4723`
