# 钱包过期快照重采样：生产维护

2026-09-10 已按 ADR-0061 部署。入口规则沿用 app-release-deployment.md；生产基线以本页和实际容器为准，不重跑旧钱包 0038/0041 迁移脚本。

## 当前部署

- 服务器：`ssh -J jumper -p 23421 root@207.56.8.8`。
- 发布目录：`/opt/starchat/releases/reserve-resampling-20260910/`，含受限配置快照、数据库备份、候选/回退配置与校验脚本。该目录含生产凭据，禁止复制整个目录或输出完整 Compose 环境。
- API：`sha256:0d330c6e2172c637b28fca9d788ea511b718af6698cbf904570257dfe6f4a839`。
- Worker：`sha256:3cf135766777f807f6d5df88c81baf20c24076b3a07577e7d75768bf50385aa2`。
- 数据库保持 `0059_chat_payment_pin`；本次不迁移、不恢复生产数据库、不修改资金控制。
- Worker 预算显式为 60 秒；API 同步监控构造仍默认 0，保留旧的 200ms 短重采样。

两个服务基于各自原镜像，仅增加修复文件；同时核对 `/opt/business-api/app` 和 Worker 实际导入的 `/usr/local/lib/python3.12/site-packages/app`。API 既有 payment_pin 配置保留。启动配置冻结在 `business-api-release.json` 与 `business-worker-release.json`，因此只改根目录 `.env` 不会改变本次冻结的运行环境。

## 只读验收

在服务器运行：

```sh
python3 /opt/starchat/releases/reserve-resampling-20260910/server_release.py verify
python3 /opt/starchat/releases/reserve-resampling-20260910/verify_modules.py
python3 /opt/starchat/releases/reserve-resampling-20260910/postflight.py
docker exec -i starchat-business-worker-1 python - < /opt/starchat/releases/reserve-resampling-20260910/read_state.py
```

公网 API 使用 `https://liuhetong888.com`，服务器与工作站均验证：`/api/v1/health/ready` 返回 200、JSON 的 ok=true/database=ready；`/api/v1/app-updates/latest` 未登录返回 401/AUTH_REQUIRED。`www.liuhetong888.com` 是静态站点，其 HTML 200 不能证明 API 就绪。

检查至少数轮监控成功心跳、last_error_code、容器重启计数、源健康及资金控制。等待 STARTED 不等于成功；超时和新故障仍阻断。事故处置仍依 wallet-incident-recovery.md，不直接修改数据库标志。

## 回退

当前版本出现回归时，先确认服务仍属于此发布及回退镜像可用，再运行：

```sh
python3 /opt/starchat/releases/reserve-resampling-20260910/server_release.py rollback
```

该命令停止 Worker、恢复原 API 和 Worker 镜像及冻结配置，只重建这两个服务。保留追加账本、事故与审计；不恢复数据库、不解除暂停。修改预算为 0 需要在本次最后一层 Worker 配置中显式修改并重新校验/发布，不能假定改 `.env` 即生效。

## 独立时间故障

部署前复测主机比多个 HTTPS Date 参考快约 58 秒，timesyncd 活跃但 NTPSynchronized=no，NTP 请求超时。超时不能单独证明出站端口被封；HTTPS Date 受秒级精度、RTT、缓存影响，不用于自动校时。

本次未调整时钟、NTP、网络策略。需另行验证批准的 NTP 源及双向网络路径，再选择受控渐进校准或维护窗口校正。不得把向后跳时视为无风险；TOTP、令牌、租约和时间戳顺序都会受影响。重采样不替代正确对时，亦不放宽 180 秒期限。
