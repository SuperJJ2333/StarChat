# 容量压测数据与 Synapse worker 化实施包（2026-08-31）

## 一、实测数据（生产环境，k6 0.54.0）

### 1. HTTP 业务层基线（经公网网关 https://liuhetong888.com）

- 阶梯：10 → 100 → 200 → 400 VU（约 2.5 分钟）
- 结果：**847 req/s**（每迭代 2 请求），`health/live` 全 200；p95 = **517ms**、p90 = 465ms、max 928ms
- 说明：脚本中 `app-updates/latest` 无鉴权返回 401 被计为 failed（50%）——为预期路径，非故障

### 2. Matrix sync 长轮询定容（容器网络直连 synapse:8008）

- 阶梯：20 → 100 → 200 → 200 VU（约 3.5 分钟），每 VU 持续发起 `GET /_matrix/client/v3/sync?timeout=30000`
- 结果：**22479 次 sync、100% 成功、0 失败**；p95 = **514ms**、p90 = 467ms、avg = 230ms；吞吐 106.5 sync/s；vus_max = 200
- 鉴权链路：业务 JWT → `matrix-login-token` → synapse `m.login.token` 登录，全通

### 3. 定容结论（1 万在线）

| 观测点 | 200 并发实测 | 1 万在线外推 | 判断 |
| --- | --- | --- | --- |
| HTTP 业务层 | 847 rps @ p95 517ms | 稳态 ~200-400 rps（心跳/操作） | **余量充足** |
| Matrix sync 连接 | 200 连接零失败 | **1 万挂起连接** | 需要 ③ worker 化 + 连接池扩容 |
| 数据库 | 业务 PG 独立实例（本轮池 10+15/worker×2） | 消息风暴时条目写入翻倍 | 需压测消息写入场景 |

**结论**：HTTP 业务层已具备万级用户稳态余量；**瓶颈在 Synapse 单体的 sync 挂起连接与单连接池（cp_max 10）**——完成 ③ 后建议分阶段复测（1000 → 3000 → 10000 并发）。

脚本与数据：`/tmp/k6/{http-baseline,sync-load}.js`（服务器）；token 等 TEMP 文件已用后不敏感。

## 二、Synapse worker 化实施包（待维护窗口切换）

### 变更清单（建议维护窗口 ~15 分钟，含回滚预案）

1. `/data/homeserver.yaml`（主 synapse）追加 replication listener：
   ```yaml
   listeners:
     - port: 9093
       bind_address: '0.0.0.0'
       type: http
       resources:
         - names: [replication]
     - port: 9134
       bind_address: '0.0.0.0'
       type: http
       resources:
         - names: [client]   # 主进程保留非 sync 客户端端点
   ```
2. 新增 worker 配置 `/opt/starchat/infra/synapse/sync-worker-1.yaml`（generic worker，处理 `/sync` 长轮询）：
   ```yaml
   worker_app: synapse.app.generic_worker
   worker_name: sync-worker-1
   worker_listeners:
     - port: 8081
       bind_address: '0.0.0.0'
       type: http
       resources:
         - names: [client]
         - names: [replication]
   worker_replication_host: synapse
   worker_replication_http_port: 9093
   worker_log_config: /data/log_config.yaml
   ```
3. compose：新增 `synapse-sync-worker-1` 服务（同镜像，command 含 `-c /data/worker/sync-worker-1.yaml`，挂载同 synapse 数据卷 + worker 配置，depends_on synapse + redis）。
4. nginx：新增 upstream `synapse_sync_worker`，把 `~ ^/_matrix/client/(r0|v3|v1)/sync$` 与 `^/_matrix/client/(r0|v3|v1)/events$` 路由到 worker，其余客户端端点维持主 synapse。
5. 主进程需开启 redis（worker 模式 v1.132 推荐经 redis 转发 replication）：`redis: { enabled: true }`。

### 验证与回滚

- 切换前：worker 容器单独启动，`curl http://<worker>:8081/_matrix/client/versions` 验证；带 token 验证 `/sync` 200。
- 切换后：k6 复跑 sync 定容脚本（同 200 VU）对比 p95/失败率；客户端实测收发消息。
- 回滚：nginx 注释 worker 路由 reload（秒级）；worker 容器停止；主 synapse 配置还原重启。

### 安全隐患（顺带记录）

- `registration_shared_secret` 为默认值 `"change-this-registration-shared-secret"`——**建议立即改为强随机**（拥有它即可注册任意用户）。


## 三、后续落地记录（2026-08-31 补）

- **下载链接双写漂移（用户可见故障）已根治**：落地页 JS `admin-home.js` 硬编码
  `releaseVersion = "0.3.5"` 并在浏览器端覆盖下载按钮——桌面 HTML 静态内容是 0.3.14、
  用户浏览器实际渲染的却是 0.3.5 链接（手机访问 /mobile_guide/ 同源同病）。
  已将 `frontend/src/`（32 文件）回拉本地仓库消除漂移，下载链接改为
  **版本无关稳定别名** `/downloads/latest-<abi>.apk`（服务器侧符号链接指向当前版本 APK），
  今后发版只更新符号链接、不再改任何页面。
- 外部验证脚本同步更新为别名断言，`latest-arm64.apk` 200 且字节与 0.3.14 一致。
- **发版流程新增一步**：创建 `latest-<abi>.apk` 三个符号链接（ln -sfn）指向新版本 APK。
