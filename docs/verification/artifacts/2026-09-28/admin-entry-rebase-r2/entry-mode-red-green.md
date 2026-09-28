# 管理会话入口绑定本地红绿证据

范围：独立 `admin-entry-merge` 工作树；未连接生产，未冻结 v4 发布包。测试日志中的合成 JWT 已脱敏。

## 修改前红灯

- `pytest -q tests/business_api/identity/test_staff_login.py -k 'staff_entry_session_cannot_gain_administrator_access_after_promotion or staff_entry_session_can_refresh_while_role_is_unchanged'`：1 failed / 1 passed。客服登录后外部晋升为 `SUPER_ADMIN`，旧 Bearer context、用户目录、Cookie refresh、step-up 实际均返回 200；原始输出见 `red-entry-mode.log`。
- `pytest -q tests/business_api/identity/test_staff_login.py -k 'existing_unmarked_management_session_requires_login_again or administrator_entry_session_expires_when_superadmin_role_is_removed'`：2 failed。无入口标记的旧会话没有失效；管理员角色撤销后旧会话仍可访问。
- `pytest -q tests/business_api/test_migrations.py -k 'wallet_and_moments_merge_is_the_only_head or admin_entry_mode_expands_session_without_trusting_existing_rows'`：2 failed，因为 0092 不存在；原始输出见 `red-entry-migration.log`。

## 修改后绿灯与影响

- 上述四个入口用例：4 passed。旧 `NULL` 会话以及入口与当前 `SUPER_ADMIN` 状态不符的会话返回 401 `ADMIN_SESSION_REPLACED`；正常客服可续期，管理员验证码重新登录后可访问管理员目录。
- 两个迁移用例：2 passed。唯一 head 为 0092；离线 SQL 包含可空 `entry_mode` 与 `STAFF`/`ADMIN` 约束，不更新旧行。
- 限定身份、管理会话、客服改密、用户目录回归：88 passed / 1 failed，原始输出见 `entry-mode-focused.log`。唯一失败是角色在目录查询期间被撤销后状态由原预期 403 改为 401；响应没有外发邮箱。将该断言改为 401 `ADMIN_SESSION_REPLACED` 后单测复跑 1 passed。
- 钱包会话边界与客服订单调用限定回归：59 passed / 2 failed，原始输出见 `entry-mode-boundary.log`。两处失败均由测试手工构造的有效 `AdminSession` 仍为旧 `NULL` 入口产生；给有效管理员 fixture 明确 `ADMIN` 后，两个目标用例的首次复跑为 1 passed / 1 failed。余下失败是读过程中撤销管理员角色后旧测试期待 403；现按新入口绑定断言 401 `ADMIN_SESSION_REPLACED` 且钱包内容不外发，复跑 1 passed。旧 `NULL` 会话必须拒绝的负向用例没有改动。
- 另跑手工充值案例与客服出款专项：27 passed / 1 failed。失败是旧手工充值测试期待撤销 wallet grant 后 GET 被拒，与已批准的只读免 grant 行为冲突；改为断言 GET 200 且内容一致，并补 POST 403 `WALLET_ACCESS_REQUIRED`，目标用例复跑 1 passed。
- 普通 App 会话及刷新恢复专项：`test_mobile_sessions.py`、`test_refresh_recovery.py` 共 55 passed。
- `scripts/export_openapi.py --check`：`OpenAPI contract: PASS`；六个受影响 Python 文件 `py_compile`：退出码 0；相关已追踪 diff 的 `git diff --check`：退出码 0（仅有 Git CRLF 提示）。

尚待发布门禁：恢复 r2 生产切换后重冻基线；0092 隔离 PostgreSQL 迁移与旧行验证；v4 候选及 0092 兼容回退镜像隔离启动；领域/规格和独立质量/安全复核；完整验证与生产发布。
