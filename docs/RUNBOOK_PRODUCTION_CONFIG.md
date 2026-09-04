# 生产服务器配置运维手册（模板渲染 / 漂移检测）

**目的**：服务器上的一切可推导配置（homeserver/nginx/element/sygnal 骨架）
都由仓库模板渲染产生，服务器**永不手改**——杜绝 2026-09-04 TURN 事故
（homeserver 副本残留内网地址与 dev 密钥）与 0.3.32 nginx inode 事故。

## 1. 真源与映射

| 仓库模板 | 服务器目标 | 渲染策略 |
| --- | --- | --- |
| `infra/synapse/homeserver.yaml.template` | `data/synapse/homeserver.yaml` | **总是**（幂等重渲染） |
| `infra/nginx/nginx.conf.template` | `data/nginx/nginx.conf` | **总是**；**原地写保 inode**（bind-mount） |
| `infra/element/config.json.template` | `data/element/config.json` | 总是（渲染产物必须为合法 JSON） |
| `infra/sygnal/sygnal.yaml.template` | `data/sygnal/sygnal.yaml` | **仅首次**（该文件将来含真实 FCM/APNs 凭据，手工维护） |
| `infra/sygnal/nooppushkin.py` | `data/sygnal/nooppushkin.py` | 总是（静态拷贝） |
| `docker-compose.yml` + `docker-compose.production.yml` | 同名 | scp 直拷（生产 overlay 含 coturn TLS 与网关回环端口） |

变量来源：服务器 `.env`（密钥仅此一处；`chmod 600`）。
同源机制：`scripts/init_matrix.ps1`（dev）渲染同一批模板。

## 2. 标准更新流程（服务器）

```bash
# 0) 备份（时间戳）
TS=$(date -u +%Y%m%dT%H%M%SZ)
cp .env .env.bak-$TS && cp docker-compose.yml docker-compose.yml.bak-$TS \
  && cp docker-compose.production.yml docker-compose.production.yml.bak-$TS

# 1) 同步仓库文件（本机执行；scp 清单见 §3）
# 2) 按需修改 .env（新增变量先加 .env，再渲染——顺序错了会把占位值写进 homeserver）
# 3) 漂移预检（只比对不写；漂移 exit 1）
python3 infra/render_config.py --check --require-production

# 4) 渲染（原地写，保 inode；未解析 token/非法 JSON/占位值 → 硬失败）
python3 infra/render_config.py --require-production

# 5) 生效
docker compose -f docker-compose.yml -f docker-compose.production.yml config -q
docker compose -f docker-compose.yml -f docker-compose.production.yml up -d
# nginx 变更：inode 已保全，reload 即可（无需重启容器）
docker compose -f docker-compose.yml -f docker-compose.production.yml exec gateway nginx -t \
  && docker compose -f docker-compose.yml -f docker-compose.production.yml exec gateway nginx -s reload

# 6) 回归
curl -s -o /dev/null -w '%{http_code}\n' https://<域名>/_matrix/client/versions   # 200
curl -s -o /dev/null -w '%{http_code}\n' https://<域名>/api/v1/health/live        # 200
```

## 3. 本机同步清单（scp）

```
infra/synapse/homeserver.yaml.template  infra/sygnal/sygnal.yaml.template
infra/nginx/nginx.conf.template         infra/sygnal/nooppushkin.py
infra/element/config.json.template      infra/render_config.py
docker-compose.yml  docker-compose.production.yml
```

## 4. 红线与已知事项

- **改 `.env` 后必须 `up -d`（或 `--force-recreate`）**——`docker compose
  restart` 不重载环境变量（0.3.34 曾因此误判 MasterSecret 无效）。
- **macaroon/form secret 目前是占位值**（历史上线即如此）——渲染按 `.env`
  原样复现；**轮换它们会导致全员登出**，属独立运维决策，勿在配置同步中"顺手修复"。
- **网关只绑 `127.0.0.1:9443`**：公网 80/443 由宿主边缘层（caddy）终止
  TLS 后回源——边缘层属**仓库外资产**，变更需在服务器上单独操作并另行记录。
- `--require-production` 拒绝 TURN_SECRET/URI 的 `change-this`/
  `development-`/`10.0.2.2`/`matrix.localhost:5349` 占位特征与非 https
  的 PUBLIC_BASEURL——TURN 事故类根因在渲染期即被拦截。
- 例行漂移检查：任意时间 `python3 infra/render_config.py --check`，
  exit 0=零漂移。建议每次发布前执行。
