# 后台管理改造验证记录

用户于 2026-09-08 确认设计及 ADR-0059 后实施。初始交付为工作区代码、迁移、合约、测试和运行说明；随后用户明确授权生产发布，已执行 0055 迁移并发布。钱包暂停和账本保持不变，详见本文生产补记。

## 实现范围

- 独立管理员会话：登录起绝对 48 小时、短访问令牌、HttpOnly Cookie 续期、新登录撤销旧会话，普通移动端会话隔离。
- 跨标签会话绑定、失败退出后的本地失效、资金写入不重放、保留草稿的近期身份验证。
- 固定且可收缩/隐藏的侧边栏，统一右上角刷新入口；按真实状态展示暂停/恢复操作。
- 香港自然日注册趋势；Decimal 点钻总量、发行/回收/冲正及审计凭证查询。
- 浅色简约后台样式、响应式抽屉、键盘焦点与 reduced-motion。

## 红绿证据

证据根目录：`docs/verification/artifacts/2026-09-08/admin-modernization/`。

- `auth/`：先验证缺失管理会话行为失败，再实现；最终 HTTP/服务/近期认证 20 项通过，PostgreSQL 并发及迁移 13 项通过，较广身份套件 184 项通过（其中 PostgreSQL 在专项单独运行）。
- `reports/`：真实日期聚合、超 JS 安全整数的两位小数、发行/回收/手续费/托管/冲正与审计异常；21 项后台测试通过。
- `wallet-ui/`：35 项状态、表单保留、部分失败及恢复测试通过。
- `chain-refresh/`：10 项链上只读查询/刷新测试通过，旧数据和选中详情在失败时保留。
- 前端新增模块最初因缺失实现失败；另外观察并修复了刷新失败后残留令牌、跨账号刷新与失败退出隐式登录问题。最终 `frontend-final.txt`：93 项通过、0 失败。
- `cdp-overview.json`、`cdp-wallet.json`、`cdp-mobile.json`：Chrome DevTools 协议设置真实 1440px / 390px 视口，图表/金额、钱包暂停操作、刷新保留草稿、固定侧栏、无横向溢出、抽屉文字与 Escape 关闭通过。曾捕获窄屏旧样式字号为零的失败，修复后通过。
- `overview.png`、`wallet.png`、`mobile.png` 为人工检查过的合成数据界面截图，不代表生产金额。

## 独立审查

先规格符合性，再领域与质量/安全审查。

- `admin_backend_review`：无阻断问题。独立执行 15 项会话/报表测试通过，核对金额、事务快照、权限、Cookie/Origin、防重放与会话撤销；并发/迁移证据另由 PostgreSQL 专项提供。
- `admin_ui_review`：初审发现跨标签身份漂移、失败退出后的隐式登录、刷新失败误报、链上刷新丢失旧数据、概览状态丢失与抽屉焦点问题，均已修复。末次独立执行 17 项测试通过，报告无剩余阻断问题。

## 合约、全量验证与限制

- UI drift：PASS，17 个组件、330 个页面。
- OpenAPI 导出并 `--check`：PASS。
- 全量 `scripts/verify.ps1` 的业务后端部分：1381 passed / 34 skipped，耗时 492.45 秒。其余阶段也已全部完成，命令退出码 0，末行 `Verification: PASS`。移动端边界 66 项通过；Python AST 190 文件通过；Alembic 单头/离线迁移及 Docker Compose 渲染通过。
- 已观察到的警告为现有测试依赖弃用提示（Starlette/httpx、Getui Pydantic 配置），未通过过滤警告或放宽测试规避。
- 远端 Figma 沿用既有用户授权暂缓同步，依据已批准的 `2026-09-08-admin-login-repair.md` 和 `2026-09-08-admin-wallet-password-apple-ui.md` 计划。此次只更新本地导出台账与 UI 注册信息，没有修改远端节点，不声称 Figma 已同步。
- 隔离 PostgreSQL 已停止，测试数据库目录保留在证据目录。无生产发布、真实钱包操作或用户消息发送。

运行和发布/回退要求见 `docs/runbooks/admin-console-sessions-and-reports.md`。必须先应用 0055 扩展迁移；回退保留新表和撤销记录，不能直接恢复缺少管理会话边界的旧应用。

## 最终浏览器补充

`cdp-reauth.json`：使用当前实际 admin-home/admin-api/admin-session 与钱包组件，在隔离 HTTP 测试响应下验证近期认证 → 保留页面 → 手动重试 → 原幂等键复用 → 领取成功。未自动重放，访问令牌不写入 sessionStorage。四个浏览器检查最终全部 PASS。

## 生产补记

已按用户明确授权完成生产发布和会话迁移。API 健康，静态文件哈希、验证码、访问与跨来源拒绝检查通过；生产注册趋势和点钻报表正常，账本总量核对一致。详细发布、备份恢复及安全回退证据见 `docs/verification/artifacts/2026-09-08/admin-modernization/deployment/README.md`。管理员需重新登录一次。
