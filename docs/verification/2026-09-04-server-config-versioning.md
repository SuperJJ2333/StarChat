# 服务器配置纳入版本管理（2026-09-04）：模板渲染 + 漂移检测

任务来源：用户批准的提案——"nginx/homeserver 等改为从仓库渲染，杜绝
服务器副本漂移（TURN 事故的根因）"。纯基础设施变更，**客户端零改动**
（无版本号/APK 变化）。

## 1. 收敛前的漂移全景（探索证据）

| 配置 | 仓库（旧） | 服务器（live） | 后果风险 |
| --- | --- | --- | --- |
| nginx 模板 | `infra/nginx/nginx.conf` 有 {{}} 变量但**无任何脚本渲染**，且缺 getui/sygnal 路由 | 手工追加 getui_bridge/sygnal upstream + 两个推送 location | 服务器是唯一真源；重装/迁移即丢 |
| `.env` | `.env.example` 有 `TURN_URI_TLS` | **缺失** | 任何重渲染会把线上 turns URI 写回 `turns:matrix.localhost:5349` 占位（TURN 事故模式的复发路径） |
| element 模板 | brand 六合通 / disable_custom_urls false | 手改为 畅聊 / true | 重渲染会回滚手改值 |
| compose（base） | coturn TLS 注释态 | TLS 生效 | 两份文件分叉 |
| compose（production） | 网关 `80:80`+`443:443`、多余 sygnal 空块 | 网关仅 `127.0.0.1:9443:443`（公网由宿主 caddy 边缘承担） | 若按仓库文件 up 会与 caddy 抢 443 |
| homeserver | 模板含 push.include_content | 线上缺 push 块 | E2EE 边界缺服务端显式声明 |

## 2. 落地机制

- **`infra/render_config.py`**（服务器可直接运行，stdlib-only）：
  - 渲染映射与 init_matrix.ps1 同源；homeserver/nginx/element 总是幂等渲染，
    sygnal.yaml 仅首次（保护未来凭据），nooppushkin 静态同步；
  - **原地写保 inode**（单文件 bind-mount 语义，0.3.32 inode 事故的结构性
    杜绝；nginx 变更只需 `nginx -s reload`）；
  - `--check` 漂移检测（exit 1）；`--require-production` 拒绝 TURN 类
    占位值（`change-this`/`development-`/`10.0.2.2`/`matrix.localhost:5349`）
    与非 https BASEURL——TURN 事故根因变为渲染期机器拦截；
  - 未解析 {{TOKEN}} / element 非 JSON → 硬失败；不打印任何 env 值。
- **模板对齐线上真源**：`infra/nginx/nginx.conf.template`（更名，含 5
  upstream + getui/notify 路由）；element 模板 brand 畅聊/disable true；
  README 引用更新。
- **compose 收敛**：production overlay 增 coturn TLS override（完整 command
  重述 + 证书挂载 + 5349）+ 网关 `127.0.0.1:9443:443`（注释说明 caddy
  边缘为仓库外资产）+ 删 sygnal 空块。
- **init_matrix.ps1** 补渲染 nginx（dev 默认 localhost 域名）；
  **verify.ps1** 接入 `tests/infra`（10 用例：inode 保真/占位拒绝/漂移
  退出码/sygnal 防覆盖等）与 nginx 未解析 token 断言。
- **`docs/RUNBOOK_PRODUCTION_CONFIG.md`**：标准流程（备份→.env→--check→
  渲染→up -d→reload→回归）、红线（restart 不重载 env；macaroon 占位值
  轮换=全员登出勿顺手改）、同步清单。

## 3. 生产收敛执行记录（2026-09-04 09:08–09:10）

| 步骤 | 结果 |
| --- | --- |
| 备份 | `.env`/两 compose/nginx/homeserver/element → `*.bak-20260904T090834Z` |
| `.env` | 追加 `TURN_URI_TLS=turns:liuhetong888.com:5349?transport=tcp`（现线上值） |
| 同步 | scp 模板×4 + render_config.py + 两 compose → `/opt/starchat` |
| 预检 | `--check --require-production` → 如期报告 3 文件漂移；**脱敏 diff 预览确认全部安全**（homeserver：push 块新增 + 密钥行按 .env 真源对齐；nginx：仅注释；element：空行） |
| 渲染 | 3 文件更新（原地写）；**二次 --check = NO DRIFT** |
| 生效 | `docker compose -f docker-compose.yml -f docker-compose.production.yml config -q` → `up -d`（全部容器 Running，无重建）→ 网关 `nginx -t` PASS + reload |
| 公网回归 | synapse/api/element/getui-notify 全 200；sygnal-notify 400（空载荷预期）；TURN 3478 TCP OK |
| 容器 | 13 个 starchat 容器全部 Up（healthy 保持） |

## 4. 已知事项（如实记录）

- homeserver 新增的 `push: include_content: false` 与密钥行对齐需 synapse
  **重启**才生效——本次刻意不重启（内容变更仅注释/push 块，无紧急性），
  下次计划内维护窗口随 `up -d --force-recreate synapse` 生效。
- macaroon/form secret 仍为历史上线的占位值（.env 即占位）——按 runbook
  红线**不得顺手轮换**（全员登出），属独立运维决策。
- 宿主 caddy（公网 80/443 TLS 终止）与托管商安全组仍为仓库外资产。

## 5. 防漂移闭环

今后任意时刻服务器执行 `python3 infra/render_config.py --check
--require-production`：exit 0 = 服务器配置与仓库模板完全一致；任何手改
立即被检出。发布流程（RUNBOOK §2）已将其固化为第 3 步。
