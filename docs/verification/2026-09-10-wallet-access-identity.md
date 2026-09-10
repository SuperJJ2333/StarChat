# 钱包60分钟验证态：身份后端验证

范围：批准计划 `docs/superpowers/plans/2026-09-10-wallet-access-grant.md` 的身份领域实现；本记录不代表生产已部署，不包含全局路由/页面验收。

## 文件与公开接口

- 新增 `app/modules/identity/wallet_grant.py`、`wallet_grant_models.py`、`app/api/wallet_access.py`。
- 修改 `app/api/admin_wallet_auth.py`、`app/modules/identity/wallet_access.py`、`operation_password.py`、`app/core/config.py`、`migrations/env.py`。
- 新增迁移 `0062_wallet_access_grant`（仅依赖生产现有 `0059_chat_payment_pin`），创建grant与TOTP尝试窗口表；`0063_merge_wallet_access`仅合流本地移动端分支。生产仅指定upgrade 0062，不能用head带入0060/0061。
- `wallet_grant_service(settings, factory, clock).require(claims=claims)`验证读访问；`.authorization(claims=claims)`返回 `authorize(session)->final()`，不提交金融调用者事务。
- `create_wallet_access_router`完整内部路径 `/wallet/manual/access`：GET状态、POST `/verify`、POST `/revoke`；main外层添加 `/api/v1`。
- JSON字段：enabled、verified、auth_mode、configured、grant_id、verified_at、expires_at、server_time；configured表示实际可用凭据；无浏览器秘密缓存。
- 特性默认关闭。开启后grant用于现有owner + SYSTEM_ADMIN管理钱包作用域；不向其他查询角色发放owner授权。关闭时状态接口不访问新增表或要求owner，保留旧前端角色/回退兼容。

## 实现约束

固定60分钟，不滚动续期；真实后台会话先到期时截断钱包截止时间。验证允许后台登录年龄大于5分钟，但不改48小时后台会话。会话/设备/用户、角色记录、登录密码及所选钱包凭据摘要、配置版本均绑定；当前会话与安全保护期每次检查。金融回调在锁等待后重验；撤销与验证并发时不会覆盖撤销。

操作密码复用既有持久失败窗口和审计；TOTP复用一次性消费验证器、现有钱包限流器，另有持久5分钟5次尝试窗口、尝试/失败审计。选择的验证方式不会降级到另一方式。API错误密码/验证码返回403，真实后台会话失效保留401。

凭据设置/更换仍保留显式验证。其只读配置查询新增 `status(grant_verification=True)`，只放开近期登录年龄，保留真实身份/角色/会话校验，供未配置凭据的引导页面使用。

## 执行证据

- Red：新增首批12测试均因缺少 `wallet_grant_service` 失败。
- Red：TOTP持久限制与verify期间revoke测试分别复现未限制尝试、撤销被覆盖；实现后通过。
- Green：PowerShell 7，UTF-8，无BOM；`PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`、`PYTHONPATH=services/business-api`。
- 命令：`.venv/Scripts/python.exe -m pytest tests/business_api/identity/test_wallet_access_grant.py tests/business_api/identity/test_operation_password.py tests/business_api/identity/test_wallet_access.py -q`。
- 结果：52 passed，10.96秒；1条本地Starlette/httpx弃用警告（环境所装版本提示改用httpx2；未修改锁定依赖）。
- 覆盖：5分钟以后验证、59:59/60:00、真实48h边界截断、不续期、跨scope/family、角色/owner/设备/family/配置/凭据/flag失效、final回调过期、TOTP replay与跨实例限制、verify/revoke竞态、无秘密审计/Outbox、HTTP refresh/no-store/403、flag关闭且删去新增表的兼容。
- 迁移测试直接执行独立expand upgrade，仅创建两张新增表；downgrade明确拒绝删除撤销记录。
- Alembic命令（工作目录services/business-api）：`../../.venv/Scripts/python.exe -m alembic heads` → 唯一 `0063_merge_wallet_access (wallet_access) (head)`。

## 尚需整体交付验证

根协调者负责真实钱包路由、跨模块事务/PostgreSQL并发、前端、全仓verify、两轮审查及生产部署。本地 `.venv` 无ruff、coincurve，lint和TRON相关全套未在本身份子任务环境运行；不能把上述独立身份测试扩大为全仓通过。

## PostgreSQL并发补充与重复撤销修复

根协调者追加授权：在服务器创建network=none的独立PostgreSQL容器，恢复现有受限备份，仅运行候选镜像与合成身份数据。工件位于 `docs/verification/artifacts/2026-09-10/wallet-access-pg/`。

首轮真实PG验证：旧候选 `1108de2a82a81832f8968e3009530935c09b01bafbe4532fadcd12b55f4653a6` 的6项检查通过，但发现已撤销记录再次验证期间收到第二次revoke时，撤销墓碑不变，验证可能覆盖撤销。证据 `result-before-fix.json` 明确记录 `FAIL_REVOKE_OVERWRITTEN`，不是通过声明。

已获准修复：每次显式revoke都更新grant_id为新UUID并追加审计，即使此前已经撤销、时钟时间未变化，也取消基于旧墓碑开始的验证。新增previous_revoke=True用例先失败后通过。修复后本地相同三文件命令结果：53 passed，12.23秒；仍有上述环境弃用警告。

真实PG测试检查：10分钟旧登录可签发、未验证读拒绝但安全配置元数据可读、59:59/60:00、两个同时verify收敛同grant、真实grant行锁等待后过期、金融final回调在真实下游行锁等待后过期回滚合成写、revoke序列化于已持锁授权之后，以及重复revoke竞态。前后对恢复库全部42张ledger/wallet金融表计算行数和全行摘要，未发生变化；仅使用合成账号，生产写入为0。

最终候选镜像 `sha256:761de90814312b3b85bfaaef6caa65f491dd35e1c1493b960edda4cf245374ef` 已在全新隔离恢复库复测通过，结果见 `wallet-access-pg/result.json`：6组基础授权/并发检查、重复revoke竞态检查及42张金融表完全不变检查均通过。runner退出码0，8.18秒。恢复、0062独立迁移均成功；仍是1个合成账号、生产写0。隔离容器使用tmpfs，按明确名称与label复核后清理；随后docker按测试label查询无残留容器。
