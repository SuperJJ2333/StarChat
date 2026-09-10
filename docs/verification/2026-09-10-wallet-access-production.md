# 钱包页面 60 分钟验证 — 2026-09-10

用户明确授权部署。批准范围见 ADR-0064、`docs/superpowers/plans/2026-09-10-wallet-access-grant.md`。已完成生产切换与验证，发布操作及回退见 `docs/runbooks/wallet-access-deployment.md`。

## 实现与验证

- 后台登录保持 48 小时；钱包授权固定 60 分钟并受后台会话截止时间约束。真实管理员、设备、family、角色、凭据/配置版本每次重验；资金提交前再次验证。
- 入口模态遮挡、禁止钱包预加载；不保存密码/TOTP；到期清空钱包内容；普通操作无需重复证明；未确认请求按账号保留且不自动重放。
- 11 项接口边界测试先失败后通过；完整应用测试覆盖概览无钱包预加载、无授权拒绝、旧登录及第 59 分钟钱包读取、撤销后后台仍可用。
- 身份最终 53 项测试通过；前端最终全套 146 项通过。两项真实浏览器场景通过，见 `2026-09-10-wallet-access-frontend.md`。
- PostgreSQL 最终候选的 8 项检查通过：59:59/60:00、并发验证、真实锁等待后到期、提交失败回滚、撤销串行化、重复撤销竞态以及 42 张金融表摘要保持不变。仅独立恢复库创建 1 个合成账号；生产数据写入 0。详见 `artifacts/2026-09-10/wallet-access-pg/result.json`。
- 评审先发现初始化密码死锁、关闭开关兼容性和授权截止时间问题，修复并复审通过。PG 复现重复撤销竞态后增加每次撤销唯一标识，red/green 后独立安全复审通过。
- 发布脚本的迁移凭证/实时 schema 检查已补严；4 项发布故障测试通过。领域与质量/安全审查均 PASS。OpenAPI 导出校验 PASS。
- 本机测试依赖有现有 Starlette/httpx 弃用警告；未修改部署锁定依赖。

## 候选和演练

当前生产基线 API：`sha256:5ca2e95d14ce6b82cd8915f00a84f2dc4643b2fcddabbd576e49ddf7a7aef4ee`。

最终候选 API：`sha256:761de90814312b3b85bfaaef6caa65f491dd35e1c1493b960edda4cf245374ef`。

发布清单包含 16 个 API/迁移文件和 7 个后台静态文件；逐项比较生产源码，差异限定本次钱包验证。既有登录模块、首页下载内容、Worker 和网关不在清单。新增迁移仅 `0062_wallet_access_grant`，以生产 `0059_chat_payment_pin` 为前驱，不执行本地其他迁移。

数据库备份 3023406 字节，SHA256 `d3e30c8f2c7bb361cbe5ffb837623cb5a8e60584412edb5fafb5bd6d98419ca1`。备份与敏感配置仅存服务器权限受限发布目录。断网隔离 PostgreSQL 恢复、扩表迁移和候选/回退配置比对通过；临时容器按归属标签清理。

## 交互限制

启用后钱包专用验证仅适用于已配置的官方钱包管理员；未向其他角色共享其凭据或赋权。普通后台登录及其他模块权限不变。远端撤销在下一次请求即拒绝；已显示内容通过 30 秒轮询、焦点/可见性及同浏览器通知发现撤销，未实现服务器推送。已知到期时间在前端即时隐藏内容。

没有在生产伪造管理员令牌、执行资金状态切换、充值补录或校时。既有打开的后台标签页须刷新一次加载新版验证入口。

## 生产结果

- 已运行最终候选 `761de908…374ef`，API healthy，restart_count=0；所有其他容器 ID 保持不变，Worker 仍为 `3cf13576…85aa2`。
- 生产 schema 已验证为 `0062_wallet_access_grant`，两张新增表存在。原 0059 之外的移动端迁移未部署。
- 设置实读：wallet_grant_enabled=true，auth_mode=operation_password，钱包 60 分钟，后台 48 小时。
- 16 个 API/迁移文件及 7 个静态文件逐项 SHA256 匹配；首页、下载页、admin-session.js 哈希保持不变。上传包 SHA256 `93012cc486643e19adb3cd3c6c0c5059419d7003e51272089ceb7b8d9995a508` 与服务器一致。
- 服务器和工作站分别通过 7 静态哈希、readiness JSON200/database=ready、未登录钱包状态和钱包数据 JSON401/AUTH_REQUIRED。工作站普通链路出现 TLS EOF，改用既有 SSH jumper 临时 SOCKS 验证成功；证书校验全程开启，没有修改系统代理/生产网关，临时转发已关闭。见 `workstation-public.json`。
- nginx -t、最后一次 static_release.py verify 均通过。敏感配置/备份仅在服务器受限目录，工作区只收集脱敏 postflight/migration/postdeploy 结果。

## 全仓回归及并行任务影响

执行 scripts/verify.ps1：仓库/部署策略、模板、配置渲染、131 infra、28 getui、9 Matrix Bot 均通过。API/Worker 首轮 1689 passed、44 skipped、7 failed；7项均因并行任务新增 Matrix broker 迁移与钱包分支形成多head以及固定head断言。协调后，本地未部署的0063合并两个分支并同步断言，迁移/完整应用复测15 passed、6 skipped；完整Alembic SQL、唯一head、OpenAPI、204文件AST/import、UI契约（22组件/332页面）与Compose渲染通过。无需重建生产候选，因为本地合流文件及通用preflight不在本次清单。

移动端首轮67 passed、3 failed；全树秘密字面量检查已通过。一个版本号不一致由负责移动端的并行任务修复，2项版本契约复测通过。另外两项为UI注册表固定数量旧断言，已交由该任务同步；实际UI契约校验通过。上述移动端文件不在本次生产候选，本记录不声称全仓单次verify.ps1无失败。
