# A1–A5 领域复核 P2 本地红绿

工作树：`admin-entry-merge`。仅本地测试，未触碰生产或冻结发布包。

1. 客服改密入口竞态：测试在 ADMIN 入口令牌及 Cookie 外层校验后撤掉 SUPER_ADMIN、保留已开通客服角色。修复前 `StaffPasswordService.change` 成功改密，新增测试 `DID NOT RAISE AppError`；在 User 行锁内重查 `AdminSession.entry_mode=STAFF` 后，`test_staff_password.py` 11 passed，`test_staff_password_app.py` 与客服角色并发专项 3 passed / 4 skipped（需 PostgreSQL 条件）。
2. 用户目录游标：保留原 HMAC，仅篡改时间戳或 ID，修复前 API 返回 200 并改变分页边界；改为域分离 HMAC 签署规范化搜索词、时间戳、ID 后，`test_user_directory.py` 13 passed。旧游标在新算法下须从第一页重新获取。
3. 钱包事务入口竞态：先用真实 STAFF 会话通过路由令牌校验，再晋升为 SUPER_ADMIN；修复前该 STAFF family 可创建 owner 钱包 grant，并通过 operation-password 写入授权（两条新增测试均 `DID NOT RAISE AppError`）。财务事务的 `require_wallet_session` 从锁定的 AdminSession 读取入口，在初次及最终校验中核对当前角色后，两条转绿；`test_wallet_access_grant.py`、`test_operation_password.py`、`test_staff_password.py` 合计 57 passed；钱包只读/边界/客服出款/手工充值四组 71 passed。

仍需：领域/规格复核、独立质量安全复核、全量 Business API 套件、隔离 PostgreSQL 0092/兼容回退镜像及生产发布门禁。所有新增断言只使用合成账号和本地数据库。
