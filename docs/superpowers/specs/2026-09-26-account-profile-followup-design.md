# 个人信息与账号设置反馈设计

状态：已批准。用户2026-09-26反馈三项问题，并确认“按此方案正式实现”。原四项账号UI设计继续生效；此次补充替代用户名不可修改约束。

## 验收

1. 账号安全和聊天在本次账号会话内热缓存5分钟；TTL内再次进入直接显示且不发GET，过期先显示再后台singleflight刷新。仅缓存脱敏摘要/已确认群偏好，不缓存OTP、密码、证明或完整联系方式。账号切换/退出/改密失效，可信token刷新不影响同账号缓存。换绑未知结果强制权威读取，失败禁用旧安全动作；群偏好未确认写入不能绕过已有写锁。
2. 生产GET账号安全目前404，需正式交付上一轮本地已完成的账号API/worker。只读GET允许可信refresh后重试；OTP写入仍单次固定身份。候选基于当前生产镜像保留r4手机邀请码/登录及0088资料grapheme限制，完成候选/恢复/评审门禁后才进入发布授权步骤。
3. 个人信息顺序为头像、畅聊号、邮箱、手机号、昵称、个性签名、拍一拍。统一共享行组件，左固定标签、右对齐内容、统一右箭头；点击进入对应编辑页。邮箱/手机直达复用绑定流程，nickname/signature独立编辑保存，保存失败保留草稿、成功马上更新返回页。邀请区作为原附加区保留在七项之后。
4. 新改号输入6–20位ASCII，字母开头，其余字母/数字/_/-，大小写不敏感。现有注册/系统自动号兼容不变，旧号可继续使用。首次可改，此后成功改号起UTC365天冷却；同normalized无业务变更不消耗机会。
5. User.username是权威畅聊号，UUID和Matrix ID保持。成功后新号用于业务登录及好友搜索，旧号不再是登录名；旧号永久留在归属表禁止其他账号认领，以防用户名派生Matrix localpart冲突/历史二维码冒名。注册两条开户路径同时检查claims与唯一约束。
6. 查询使用normalized主键/唯一索引精确检索，不扫描或前缀匹配。可用性端点需登录、格式校验、限频、客户端防抖；可用性只供提示，最终事务唯一约束裁决。账号行锁保证同用户冷却，幂等记录/号归属/用户/审计/Outbox同事务。

## 架构与兼容

新增users.username_changed_at及identity_username_claims，迁移基于生产0088的expand，仅补表/列并回填现username与稳定Matrix localpart。冲突明确失败，禁止静默覆盖。回退保持新表/审计，不破坏性downgrade。

GET /profile/username-change返回当前号、can_change、next_change_at、6/20规则；GET /profile/username-availability?username=...返回精准可用性；PATCH /profile/username携Idempotency-Key返回username/changed/next_change_at。Profile返回新增可选masked_phone，旧客户端兼容。

保持财务、E2EE、session family、RBAC边界；改畅聊号不改密码/密钥/Matrix登录身份。UI失败/保存中/空/冷却/冲突/断网状态均在HTML catalog与Flutter一致展示。Figma已退役。

## 验证

先规格领域，再质量安全评审。缓存TTL/重进/401/换账号/迟到读写/未知换绑；7行顺序右对齐箭头/窄屏文字缩放/编辑成功失败/绑定直达；长度格式/大小写/旧号占用/注册绕过/UTC边界/并发同号和同账号/幂等/新号登录搜索/Matrix稳定。迁移隔离PostgreSQL恢复和索引计划；API契约、Flutter全量/analyze、frontend/UI合同和适用verify门禁。生产未认证401必须与历史404区分；真实OTP需受控验收，不能伪造用户会话。
