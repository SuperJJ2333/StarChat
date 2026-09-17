# 2026-09-17 生产部署：红包手续费（ADR-0073）+ 迁移 0068_red_packet_fee

用户明确指令「直接部署迁移 0068 与扣费」（2026-09-17，覆盖此前"新客户端先行"的次序选择）。
按 `docs/runbooks/admin-production-workflow.md` 与 `app-release-deployment.md` 执行：实时基线 → 候选镜像 →
隔离演练 → 备份 → 先迁移后切码 → 切换 → 双侧验证。

## 1. 实时前态（部署前重新读取，不用历史快照）

| 项 | 实测值 |
| --- | --- |
| API 容器 | `starchat-business-api-1`，镜像 `sha256:16522404d919…`（tag `starchat-business-api:app-update-platform-20260917`），workdir `/opt/business-api`，uvicorn factory ×2 workers，61 环境键，3 挂载，`127.0.0.1:8082`，unless-stopped |
| Worker 容器 | `starchat-business-worker-1`，镜像 `sha256:b5bd6973825f…`（tag `adr0071-owner-transfer-20260915-r2`），workdir `/opt/business-worker/app`，`python main.py`，65 环境键，3 只读挂载 |
| 导入路径 | API：`/opt/business-api/app/modules/redpacket/service.py`（sha `888237f2…`）；Worker：`/usr/local/lib/python3.12/site-packages/app/modules/redpacket/service.py`（sha `2eccbc75…`，与 API 副本已漂移 —— ADR-0071 r2 教训） |
| 数据库 | `business-postgres:5432/liuhetong`（user `liuhetong`），alembic head `0067_wallet_owner_transfers`，`red_packets` **52 行**、**无 `fee` 列** |
| 磁盘 | `/opt` 已用 19%，余 169G |

**部署期基线 diff（决定最小覆盖范围）**：
- API `service.py` 与仓库 HEAD 相差仅 ADR-0073 手续费 hunk（+32/−5）；
- API `models.py` 仅新增 `fee` 列与 `text` 导入；API `api/redpacket.py` 仅手续费导入/文案/响应字段；
- Worker `service.py` 与仓库 HEAD 相差 +81/−9（缺 payment_pin、F06 等**与本任务无关**的历史改动）→ **不做整文件覆盖**，
  只在该文件自身基线上做外科合并（+14/−2，仅 `_refund` 的手续费退款与 `skip_coverage` 对齐 API 语义）。

## 2. 候选镜像（基于在线镜像最小覆盖）

| 镜像 | 基座 | 覆盖内容 | 候选 digest |
| --- | --- | --- | --- |
| `starchat-business-api:redpacket-fee-20260917` | `sha256:16522404d919…` | redpacket `service.py`/`models.py`、`api/redpacket.py`（`/opt` 与 `site-packages` **两份都覆盖**）、`migrations/versions/0068_red_packet_fee.py` | `sha256:48948fb73cdf2b02f4e27acde488db178a56cad38a49d0c71bc96cb947b6e588` |
| `starchat-business-worker:redpacket-fee-20260917` | `sha256:b5bd6973825f…` | 外科合并后的 `service.py` + `models.py`（`site-packages` 路径，即 worker 实际导入位置） | `sha256:f9d03982d2ea377b79a32412586d42e29ef414a5454baca6f1ff68106df28aa5` |

payload sha256（服务器实测与本地一致）：
`service.py 9bf80df0…`、`models.py 53c19339…`、`api/redpacket.py 0ccfc142…`、
`0068_red_packet_fee.py 9f2872e7…`、worker `service.py c5cdf653…`。

## 3. 隔离演练（一次性 PG16，不接触生产库）

`postgres:16.9-alpine` 一次性容器 + 候选 API 镜像：

- **模块身份**：`app.modules.redpacket.service` → `/opt/business-api/app/modules/redpacket/service.py`，sha 等于 payload（先断言身份，避免 ADR-0071 r2 的"假绿"）。
- **迁移链**：`alembic upgrade head` 从 0 跑到 **0068_red_packet_fee**（0001→0068 全链成功）。
- **行为演练 `REHEARSAL_OK`**：`fee` 列 `numeric(20,2) NOT NULL DEFAULT 0.00`；创建 10.00 红包 → `fee=0.05`、
  发送方扣 10.05、托管 10.00、`PLATFORM_FEE=0.05`；过期退款 → 未领本金 + 手续费各退一次、二次过期无副作用；
  `fee=0.00` 的历史红包只退本金、不动 `PLATFORM_FEE`；**所有账本事务分录平衡（0 条不平衡）**。
- **回退演练**：`alembic downgrade 0067_wallet_owner_transfers` → head 0067 且 `fee` 列消失（`fee_column_count=0`）。
- **Worker 候选**：导入路径 = `site-packages/.../service.py`，sha `c5cdf653…`；`RedPacket.__table__` 含 `fee`；源码含 `fee_refund` 与 `PLATFORM_FEE`。

## 4. 备份（宿主机私有目录，0700）

- 业务库 `pg_dump -Fc`：`/opt/starchat/releases/redpacket-fee-20260917/backup/business-db-pre-0068-20260917T075309Z.dump`
  （13,098,341 字节，sha256 `824cc9845170ebfd377dcbaf64cf8a0ebf66fcdf392cf3f06c4cad80696b0c43`，0600）。
- 冻结前态：两个容器镜像 digest、env 计数、挂载、端口、`docker ps`、两处被替换文件的 sha256，全部落在同一 `backup/`。

## 5. 迁移（**先于代码切换**）

在运行中的 API 容器内 `docker cp` 0068 迁移文件后执行 `alembic upgrade head`：

```text
0067_wallet_owner_transfers -> 0068_red_packet_fee
{"alembic_head": "0068_red_packet_fee", "fee_column": "('NO', '0.00', 'numeric', 20, 2)",
 "red_packets_rows": 52, "rows_backfilled_zero": 52}
health_live=200  health_ready=200  redpacket_limits_unauth=401
```

选择「先迁移后切码」的理由：迁移是 expand-only（加可空列 → 回填 0.00 → NOT NULL DEFAULT），旧代码在迁移后
仍可正常插入（`fee` 取默认 0.00）与退款（只退本金）；反之若先切码，`INSERT ... fee` 会在列存在前的窗口内失败。

## 6. 切换

```text
docker compose --project-directory /opt/starchat -p starchat \
  -f releases/adr0071-owner-transfer-20260915/frozen-api.json -f releases/redpacket-fee-20260917/api-release.json \
  up -d --no-deps business-api
docker compose --project-directory /opt/starchat -p starchat \
  -f releases/adr0071-owner-transfer-20260915/frozen-worker.json -f releases/redpacket-fee-20260917/worker-release.json \
  up -d --no-deps business-worker
```

未使用 `/opt/starchat/docker-compose.yml`（其源码树过期，会丢环境键与只读挂载）。

## 7. 切换后验证

| 检查 | 结果 |
| --- | --- |
| 容器身份 | API `sha256:48948fb73cdf…` / worker `sha256:f9d03982d2ea…`，均 **healthy**、restart `unless-stopped` |
| 配置一致性 | env **61/61（API）**、**65/65（worker）**；API 3 挂载与 `127.0.0.1:8082` 不变；worker 3 只读挂载不变 |
| 部署文件身份 | API `/opt` 与 `site-packages` 两份均等于 payload（service `9bf80df0`、models `53c19339`、api `0ccfc142`、迁移 `9f2872e7`）；worker `service c5cdf653` + `models 53c19339` |
| 真实运行时导入 | API：`/opt/business-api/app/modules/redpacket/service.py`，含 `red_packet_fee`，路由含 `fee`；Worker：site-packages 路径，`fee` 列在 ORM，退款路径含 `fee_refund`/`PLATFORM_FEE` |
| 生产 schema | `alembic_head=0068_red_packet_fee`，`fee` NOT NULL，52 行全部 `0.00`（历史红包仍免费） |
| 健康/鉴权（服务器侧） | `/health/live` 200、`/health/ready` 200、`/red-packets/limits` 401、`/red-packets/{id}` 401 |
| 健康/鉴权（工作站侧，jumper SOCKS + TLS） | `health/live` 200、`health/ready` 200、`red-packets/limits` 401、`app-updates/latest` 401 |
| 无关容器 | 仅 `business-api` 与 `business-worker` 重建；synapse/postgres/gateway 等 Up 6–12 天未变 |
| 日志 | 切换后 API 与 worker 无 traceback/critical |

预存在（非本次引入）：worker 打印 `outbox dead-letter: 2 events have no registered consumer`；ADR-0071 r2 记录当时为 3 条，
属既有 outbox 重放运维事项（`contract` 未注册主题），需运维按重放工具处理。

## 8. 兼容性影响（用户已明确要求直接部署）

- 线上已发布客户端（≤0.3.93/2127）**不显示手续费**且按 `total` 校验余额：当「余额 ≥ total 但 < total+fee」时，
  现在会收到 422 `RED_PACKET_BALANCE_INSUFFICIENT`，文案已是「含 0.5% 手续费 x 点钻，需合计 y 点钻」。
  余额充足的用户不受影响（只是界面不展示这 0.5%）。历史红包（52 行）`fee=0.00`，退款口径与部署前完全一致。
- 已安装 Mi 6 的 **0.3.93-debug/2128** 会展示「手续费 + 实扣合计」，可作为新客户端观测面。
- 建议下一步：把含手续费展示的客户端作为正式版发布（当前正式版 2127 早于该客户端改动），以消除"展示/实扣"不一致。

## 9. 回退

1. 代码：`-f frozen-api.json -f api-rollback.json up -d --no-deps business-api`（回到 `16522404…`）、
   `-f frozen-worker.json -f worker-rollback.json up -d --no-deps business-worker`（回到 `b5bd6973…`）。
2. 扣费行为：回退代码后旧 `_create` 不再收取手续费（`fee` 列保留、默认 0.00，写入 0.00）。
3. 迁移回退：候选镜像内 `alembic downgrade 0067_wallet_owner_transfers`（仅删列，不触碰账本）。
4. 数据恢复（仅在需要时）：`pg_restore` 上文 dump；本迁移为附加列，正常回退不需要恢复数据。

## 10. 证据位置

`/opt/starchat/releases/redpacket-fee-20260917/`（0700）：`Dockerfile.api`、`Dockerfile.worker`、`payload-api/`、
`payload-worker/`、`rehearse.py`、`rehearse-run.sh`、`check_column.py`、`migrate-production.sh`、
`switch-and-verify.sh`、`pre-state-backup.sh`、`api-release.json`、`api-rollback.json`、`worker-release.json`、
`worker-rollback.json`、`baseline/`（被替换文件原件）、`backup/`（含数据库 dump 与前态快照）。

本地副本与日志：`docs/verification/artifacts/2026-09-17/redpacket-fee-deploy/`。
