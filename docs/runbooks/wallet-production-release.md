# 钱包应用生产发布：真实资金关闭模式

适用版本：2026-09-06，Alembic `0041_wallet_operations`。本发布部署日结/事故/监控代码；真实充值、兑换、提现及生产事故写入继续关闭。最近登录不能替代 MFA，Sandbox 回执不能替代外部送达。不得因本手册的部署通过而打开资金开关。


> **上线状态更新：2026-09-06 23:32 起（香港时间）已执行生产发布。** 数据库现为0041，新API/Worker已健康运行，真实资金关闭。下文0038基线及“待执行”描述保留为此次发布步骤的历史记录，不能重复运行只接受0038的 `server_config_check.py`、`deploy_release.py` 或备份脚本。当前只读验收用服务器发布目录 `postdeploy_check.py`；下次发布必须按当时基线重新准备备份与演练。
>
> 本次实际发布使用上列镜像的 **sha256 image ID** 作为Compose环境变量，避免标签漂移。后续维护仍需显式设置这两个变量后使用同一套六层配置；不使用裸 `docker compose up`。上线记录见 [2026-09-06-wallet-production-deployment.md](../verification/2026-09-06-wallet-production-deployment.md)。

## 已准备并验证的服务器工件

- 发布目录：`/opt/starchat/releases/wallet-readiness-20260906/`。
- 源码：`source/`，SHA256 清单 `source-manifest.json`；源码归档 SHA256 为 `e0a711f6a4fb8d49064014fe9df1d9b076ecc6c8c1aa9f48df930f63b225760f`。
- API：`starchat-business-api:wallet-20260906-locked`，服务器 image ID `sha256:961c3a0e1b9a32f40455ed1fe14cfa7e4a28ef9b6c2f139cb792108ca350b276`。
- Worker：`starchat-business-worker:wallet-20260906-locked`，服务器 image ID `sha256:78080de4b17ebf515278c623ec0182f19b828373747a8840bcc5ec327f9f5233`。
- 旧 API：`starchat-business-api:wallet-20260906-rollback`，image ID `sha256:3c65b6f1abddd68cc439a062587331210d7aa6f2f53218d0db0f36e0194d8b55`。
- 旧 Worker：`starchat-business-worker:wallet-20260906-rollback`，image ID `sha256:0fde9b76ad6277a5735c1bdb44bb705461d6817cc377eb59875bcd2ae3c03540`。

发布前重新检查这些 ID；镜像标签被覆盖时停止，不凭相同标签继续。不得使用无版本或 `latest` 镜像。不同机器构建产生的镜像 ID 不相同，应以部署服务器已验证的 ID 为准；共同源码/依赖记录不是跨机器位级镜像一致性承诺。

已验证备份：`/opt/starchat-backups/wallet-20260906T150926Z-265c92/`，备份 SHA256 `daaf4c103a87123a3fc6b6e5da117555bb882217ce0014616162aad4832ed10a`。数据库、环境和容器配置仅在服务器受限目录内（目录 0700，文件 0600）；工作区只保存摘要。备份在 `--network none` 的独立 PostgreSQL 中恢复成功，恢复基线为 `0038_app_settings_text`。这是当时的一致快照；实际发布前运行同目录 `prepare_server_backup.py` 刷新备份并使用其返回的新路径，不把旧快照当最新数据。

## 发布前检查

Windows 端通过 PowerShell 7 执行 SSH。本机 SSH 配置包含不可用的代理程序，本次验证采用系统 OpenSSH 的 `-F none -p 23421` 直连；未修改用户 SSH 配置或轮换密钥。

下列命令在已授权的 **Linux 服务器** 中执行。须保留生产当前五层配置，并把钱包覆盖放在最后；不能仅用基础 Compose 更新而丢掉现有功能配置。

```sh
cd /opt/starchat
export BUSINESS_API_RELEASE_IMAGE=starchat-business-api:wallet-20260906-locked
export BUSINESS_WORKER_RELEASE_IMAGE=starchat-business-worker:wallet-20260906-locked
compose=(docker compose --project-directory /opt/starchat --env-file /opt/starchat/.env
  -f /opt/starchat/docker-compose.yml
  -f /opt/starchat/docker-compose.production.yml
  -f /opt/starchat/docker-compose.feature-release.yml
  -f /opt/starchat/releases/cache-entry-0.3.45/compose.override.yml
  -f /opt/starchat/releases/settings-arm64-0.3.46/compose.override.yml
  -f /opt/starchat/releases/wallet-readiness-20260906/source/infra/compose/docker-compose.wallet-release.yml)
"${compose[@]}" config --quiet
python3 /opt/starchat/releases/wallet-readiness-20260906/server_config_check.py
python3 /opt/starchat/releases/wallet-readiness-20260906/prepare_server_backup.py
```

`server_config_check.py` 只读检查真实配置和数据库，发布前预期两个服务均返回 `MIGRATION_HEAD_MISMATCH`（生产仍为0038）。它不打印密钥或渲染后的完整环境。若基线、镜像、Compose 文件列表已经改变，先重新演练；不要跳过门禁或 stamp 新版本。

## 迁移及切换

以下是待执行的上线动作，本轮验证没有执行这些命令：

```sh
"${compose[@]}" stop business-worker
"${compose[@]}" run --rm --no-deps business-api alembic -c alembic.ini upgrade head
"${compose[@]}" run --rm --no-deps business-api python /opt/business-api/release_preflight.py
"${compose[@]}" up -d --no-deps --wait business-api
"${compose[@]}" up -d --no-deps --wait business-worker
```

迁移失败立即停止，不启动新服务，不 stamp 或清空数据库；旧 API 可继续在原结构上运行。预检成功必须为 `RELEASE_READY_FUNDS_DISABLED`，不能用 `/health/live` 替代。API/Worker 镜像均包含预检，发布配置不再在常规启动时自动迁移。

上线后检查内部及公网 `/api/v1/health/ready`、既有登录/消息功能、财务只读日报与监控状态；用户钱包配置 `funding_enabled=false`、`conversion_enabled=false`，资金写入503。Worker 无托管商时产生 `MONITOR_UNAVAILABLE` 和暂停记录是预期行为；不能把它解释为已完成真实资金监控。网关、Matrix、数据库容器及数据卷均不属于此次重建范围。

## 回退代码，保留金融证据

先停止新版 Worker。使用上面五个原始配置文件，再追加已准备的 `infra/compose/docker-compose.wallet-rollback.yml`；保留所有环境、挂载和端口。

```sh
"${compose[@]}" stop business-worker
export BUSINESS_API_ROLLBACK_IMAGE=starchat-business-api:wallet-20260906-rollback
export BUSINESS_WORKER_ROLLBACK_IMAGE=starchat-business-worker:wallet-20260906-rollback
rollback=(docker compose --project-directory /opt/starchat --env-file /opt/starchat/.env
  -f /opt/starchat/docker-compose.yml
  -f /opt/starchat/docker-compose.production.yml
  -f /opt/starchat/docker-compose.feature-release.yml
  -f /opt/starchat/releases/cache-entry-0.3.45/compose.override.yml
  -f /opt/starchat/releases/settings-arm64-0.3.46/compose.override.yml
  -f /opt/starchat/releases/wallet-readiness-20260906/source/infra/compose/docker-compose.wallet-rollback.yml)
"${rollback[@]}" config --quiet
"${rollback[@]}" up -d --no-deps --wait business-api
"${rollback[@]}" up -d --no-deps --wait business-worker
curl --fail http://127.0.0.1:8082/api/v1/health/ready
```

**旧 API 必须显式使用 uvicorn 命令**：旧镜像不认识0041，原自动 Alembic 启动命令会失败。服务器隔离环境已验证这两个旧镜像在新增结构上的启动健康，未证明旧版本提供新的日结/监控能力。保留新表、订单、Outbox 与审计；禁止 downgrade 删除这些证据，禁止用备份覆盖上线后的新账本。

普通应用回退不恢复数据库。灾难恢复必须暂停写入、核对备份截止后全部追加交易及外部订单，按独立恢复流程处理；本次断网恢复演练不承诺 RPO=0。旧 Worker 无新监控能力，回退期间须维持独立运维观察和资金关闭。

## 边界

本轮证明的是应用在生产配置下的迁移、启动、重启、代码回退和受限备份恢复。没有部署新版本到线上业务容器，也没有启用真实资金；真实 MPC、外部告警 SLA、操作 MFA、独立存证、跨故障域容灾及 iOS 分发验收另有门槛。
