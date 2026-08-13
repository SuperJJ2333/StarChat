# Docker 恢复与模拟器端口验证

日期：2026-08-14

- 仅检查和操作 Compose 项目 `starchat`。
- `docker compose ps` 确认 PostgreSQL、Redis、Business API、Worker、Synapse 运行。
- 按依赖顺序重建 PostgreSQL/Redis、Business API，再启动 Worker/Synapse。
- Business API 端口由旧的 `127.0.0.1:8082` 重建为 `0.0.0.0:8082`。
- `GET http://127.0.0.1:8082/api/v1/health/live` 返回 HTTP 200。
- `GET http://127.0.0.1:8082/openapi.json` 返回 HTTP 200。
- 两台雷电模拟器直接访问 `10.0.2.2:8082` 返回空响应；该地址不是本机雷电环境的可靠宿主机网关。执行 `adb reverse tcp:8082 tcp:8082` 后，两台模拟器访问 `http://127.0.0.1:8082/api/v1/health/live` 均返回 HTTP 200；访问本机 WLAN 地址 `192.168.1.117:8082` 也返回 HTTP 200。
- Matrix Synapse 地址：`http://127.0.0.1:8008`；模拟器地址：`http://10.0.2.2:8008`。
- Business API 地址：`http://127.0.0.1:8082/api/v1`；雷电调试通过 `adb reverse` 后使用相同地址，或通过构建时配置使用本机 LAN 地址。
- Worker 在数据库容器重建窗口内曾记录 `red_packets` 表不存在；API 完成 Alembic `0011_wallet_webhook_events` 后重启 Worker，最终状态为 healthy。
