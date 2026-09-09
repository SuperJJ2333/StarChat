# 钱包客户端与服务端联合发布核对

适用：2026-09-09 整合基线。客户端承接 Android 0.3.68/2072；本次未提高版本号或发布安装包。

## API 与认证

Flutter 以业务 API `/api/v1` 为根路径。Matrix 消息不构成余额、充值或提现依据。

| 客户端操作 | 业务接口 | 约束 |
| --- | --- | --- |
| 能力、余额 | GET `/wallet/config`、`/wallet/balances/me` | 登录会话；以服务端能力为准 |
| 地址绑定 | GET `/wallet/binding`；POST `/wallet/binding/address`、`/challenges`、`/confirm` | 按服务端认证模式选择流程，写请求携带幂等键 |
| 充值意向、恢复 | POST `/wallet/manual/deposit-intents`；GET `/current`、`/{intent_id}` | 六位小数字符串，绑定版本校验，按当前用户隔离 |
| 提现报价、申请、恢复、取消 | `/wallet/manual/payout-quotes`、`/payouts`、`/payouts/{order_id}`、`/payouts/{order_id}/cancel` | POST 携带原幂等键；收款目标来自服务端绑定，禁止客户端覆盖 |
| 兑换 | POST `/wallet/conversions` | 服务端能力、资产精度、原会话作用域及幂等键 |
| MFA | `/security/mfa` 及 enroll、enable、reauthenticate、abort-pending | 按既有认证策略执行；不得将密钥和证明持久化为恢复记录 |

`ManualWalletApi` 固定初始化时的业务账号作用域；兑换固定提交前作用域。首次发送和 401 刷新后均检查账号。相同账号刷新保留请求体和幂等键；切换账号停止发送，原账号未知结果记录保留，不能作为新账号请求重放。

地址模式 `address_only` 沿用 ADR-0058，不意味着管理员资金操作免认证。管理员角色、独立操作密码、会话撤销和其他服务端校验继续生效。普通用户不得读取其他用户提现记录，不能执行管理员认领等操作。

## 配置与迁移

API 与 Worker 必须同时核对：

- `BUSINESS_WALLET_REAL_MODE`、`BUSINESS_WALLET_USER_AUTH_MODE`、`BUSINESS_WALLET_RESERVE_POLICY`。
- `BUSINESS_WALLET_DEPOSITS_ENABLED`、`BUSINESS_WALLET_PAYOUT_REQUESTS_ENABLED`、`BUSINESS_WALLET_PAYOUT_EXECUTION_ENABLED`、`BUSINESS_WALLET_CONVERSIONS_ENABLED`。
- 旧 `BUSINESS_WALLET_REAL_FUNDS_ENABLED` 仅是未显式设置独立开关时的回退值；不能用它推断上述四项全部关闭。

不要为了让检查通过而修改线上开关。本次只读核对的线上配置是 manual_tron / address_only / manual_liquidity，四项独立能力开启、旧总开关关闭。

唯一迁移头为 `0057_merge_direct_room`，合并 `0056_merge_moment_comments` 和 `0040_direct_room_reservations`；0056 继续保留 `0055_admin_sessions` 和 `0040_moment_comment_images`。这同时保留钱包、管理员会话、朋友圈图片评论及最新私聊预约迁移。发布前读取实际 `alembic_version`，从目标现状验证迁移路径，不直接使用旧客户端分支执行迁移。当前线上已经位于该头，本次不重复迁移。

`docker-compose.wallet-manual.yml` 是本次补齐的配置覆盖层，只用于现有已审阅部署层之上。九项策略必须显式提供，API/Worker 使用同一个映射；它不负责选择镜像或覆盖启动命令。保留全部既有生产层，不能使用裸基础 Compose 发布。`TRON_WATCH_DATA_DIR` 指向已有受保护观察目录，`WALLET_HANDOVER_RECORD` 指向已有已核实交接记录；均只读挂载且禁止自动创建。不得生成空文件代替交接证据。新容器将交接记录读作 `/data/wallet-handover.json`，不修改宿主文件。

`scripts/wallet_release_preflight.py` **只认证资金功能关闭时的部署准备状态**，不认证真实资金运行就绪。它现在固定上述合并头，并逐项拒绝兑换、旧总开关及独立充值、提现申请、提现执行开启的配置；结果仅输出固定状态码。`None` 独立值继承已验证关闭的旧总开关。线上独立能力开启时，这个脚本不应返回 ready，不能据此认为线上钱包故障。

## 发布前验证与恢复

执行钱包 Flutter 测试、账户切换/刷新回归、客户端路由契约测试、API/Worker 权限与幂等回归，以及 `scripts/verify.ps1`。PostgreSQL 合成库另测完整和已有版本迁移、重复 upgrade、旧记录保留、并发管理员会话、账本不可修改及备份恢复。未经配置的外部集成测试跳过必须在报告中列出，不能作为已验收。

本次源代码以已部署 API `c76be88a7e5b` / Worker `27bc9f7de31f` 快照为底本，另含已审阅的 `TronReader` 修复：最多三次完整尝试共享截止时间，重建事件和余额，拒绝区块回退和同高度冲突；三次仍移动则结果保持不稳定。该文件与线上不同，尚未部署。下次后端发布应记录旧镜像摘要，使用新不可变镜像和合成测试证据；本修复不需要数据库变更。回滚优先恢复旧镜像，不对资金历史执行破坏性 downgrade。

Android 正式安装包仍须遵循 `android-apk-rebuild.md` 的重建、对齐、稳定签名和产物验证流程。构建需来自本次共同基线，不能只搬客户端文件。当前 Android 发布版本仍为 0.3.68/2072，iOS 不发布。
