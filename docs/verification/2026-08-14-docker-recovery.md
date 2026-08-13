# Docker 恢复与模拟器端口验证

日期：2026-08-14

- 仅检查和操作 Compose 项目 `starchat`。
- `docker compose ps` 确认 PostgreSQL、Redis、Business API、Worker、Synapse 运行。
- 按依赖顺序重建 PostgreSQL/Redis、Business API，再启动 Worker/Synapse。
- Business API 端口由旧的 `127.0.0.1:8082` 重建为 `0.0.0.0:8082`。
- `GET http://127.0.0.1:8082/api/v1/health/live` 返回 HTTP 200。
- `GET http://127.0.0.1:8082/openapi.json` 返回 HTTP 200。
- Android 模拟器通过宿主机别名 `10.0.2.2:8082` 进行 TCP 可达性检查。
- Matrix Synapse 地址：`http://127.0.0.1:8008`；模拟器地址：`http://10.0.2.2:8008`。
- Business API 地址：`http://127.0.0.1:8082/api/v1`；模拟器地址：`http://10.0.2.2:8082/api/v1`。
