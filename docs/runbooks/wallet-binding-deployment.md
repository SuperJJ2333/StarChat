# 私人钱包绑定与后台链上查询发布准备

2026-09-07 13:48（香港时间）已部署后台只读链上查询、10 USDT 门槛、绑定核心及受就绪条件限制的接口，迁移版本为 0042。**真实绑定和充提仍未开放。** SSH 已恢复，发布与线上健康检查通过；生产管理员登录后的页面验收待完成。详见[部署证据](../verification/2026-09-07-wallet-binding-deployment.md)。

## 接口与配置

- 管理接口：`/api/v1/admin/wallet/chain/summary`、`/transactions`、`/transactions/{txid}/{log_index}`。使用当前有效登录会话和 finance/audit 权限，读取详情留存事件哈希审计引用。
- 金额保持六位字符串。列表返回 `snapshot`，后续分页须携带；更换筛选或刷新时重置。详情中的完整来源/目标地址只向授权管理员返回，不写普通日志。
- `BUSINESS_TRON_OBSERVER_DATABASE_PATH` 为服务端固定观察库路径。部署叠加 `infra/compose/docker-compose.wallet-chain.yml`，将现有观察目录只读挂载到 API，不能替换、清空或重新初始化观察器数据。
- 观察器的数据覆盖起点在 summary 返回。后台展示的是该覆盖范围内已观察事件；`coverage_complete=false`，不可据此宣称全链历史完整或用户已入账。
- 绑定接口：`GET /wallet/binding`、`POST /wallet/binding/challenges`、`POST /wallet/binding/confirm`。`BUSINESS_WALLET_BINDING_DOMAIN` 必须是正式业务签名域。客户端不能传用户、会话、激活证据或就绪开关。
- 当前正式路由没有配置 MFA、账户权限及独立最终性适配器，写入接口返回 `WALLET_BINDING_NOT_READY`。仅设置域名不能开启绑定。无公开激活接口。

## 发布检查与剩余验收

1. 已核对原六层 Compose、0041 基线及镜像，并将配置哈希和 PostgreSQL 容器身份纳入变更前检查。
2. 已在服务器私有目录备份业务库及配置，并使用生产同一 PostgreSQL 16 镜像完成恢复、0042 迁移和 38 项隔离检查；账本记录数未变。生产数据库未下载到工作区。
3. 已验证新旧 API/Worker 在扩展结构上启动。回退必须保留 0042 数据，并让旧镜像挂载受审阅的新预检 `/opt/binding-rollback-preflight.py`；禁止降级删除绑定历史。
4. API/Worker 已按镜像摘要上线，观察目录只读挂载，资金预检为 `RELEASE_READY_FUNDS_DISABLED`。后台三个 JS 文件公网响应哈希与发布源一致。
5. 待完成：使用已授权管理员会话验收生产 summary/list/detail、筛选和分页。隔离角色权限检查与生产未登录 401 检查已通过；不能代替生产管理员页面验收。

## 后续运维

发布目录为 `/opt/starchat/releases/wallet-binding-20260907`。`prepared.json` 保存原六层 Compose 和旧镜像，`deployed.json` 保存新镜像摘要；`release.json` 为本次域名覆盖配置。维护时必须保留原六层、`source/infra/compose/docker-compose.wallet-chain.yml` 和 `release.json`，并使用记录的镜像摘要及观察目录，不能用裸 `docker compose up` 丢失叠加配置。

`server_release.py deploy` 是带旧基线和备份时效检查的一次性发布入口，不用于已经上线后的重复启动。紧急回退应采用脚本中经演练的 rollback 组合，先核对当前迁移状态及配置，再恢复旧镜像和备份前端；生产数据库恢复不是常规应用回退步骤。受保护备份位置见部署证据。

## 真实绑定及充提的剩余集成

真实 MFA 与私人钱包签名入口、TRON 账户权限核验、独立最终性来源、充值意图和链上归属入账、提现绑定目标/费用快照尚未完成集成。尤其在充值意图退役关闭逻辑完成前，禁止安装可实际激活绑定的 barrier adapter。独立签名、双人审批、储备与异常通知验收仍是资金启用前置条件。

生产部署就绪与真实资金启用是不同验收结果；本文件不批准绕过任一门禁。
