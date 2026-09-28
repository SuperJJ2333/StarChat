# v8 生产执行序列（去敏，待最终质量结论）

**现状与边界。** v8 已完成私有备份、双镜像双角色门禁、禁网 PostgreSQL 0091→0092 克隆、兼容回退 readiness、四组竞态及克隆清理；[阶段证据](server-stage-evidence.json)。生产仍为 API `8015e963…`、Worker `3c9e4bbf…`、schema 0091，服务与静态尚未切换。须先取得最终质量结论和发布协调；以下操作由 root 按既有跳板执行。保留 v5–v7 失败审计，不修改 v8 冻结包。

| 顺序 | 操作与必留证据 | 停止条件 |
| --- | --- | --- |
| 1. 切前重验 | 在 `/opt/starchat/releases/admin-entry-merge-20260929-v8` 核对 archive `815bb4cb…`、manifest `dc168f6a…`；运行 `python3 server_release.py preflight`，须为 0091、原 API/Worker 镜像、双 Compose SHA、21 API 与 18 静态 before SHA 全匹配。复核私有目录 root/0700、常规文件 0600、无链接、dump SHA `a211d901…`、`restore.json` 的 0091→0092、四竞态 exit0、兼容 readiness、`clone_removed=true`，及其他 27 容器名称/ID。 | 任一 SHA、schema、镜像、Compose、容器、备份或克隆证明漂移；不得沿用冻结包或重试一次性步骤。 |
| 2. 数据库扩展 | 记录迁移前 `identity_admin_sessions` 总行数（只记计数）；执行 `python3 server_release.py migrate-production`。这是**首个生产写入**，写一次 attempt 后执行非破坏 0092。随后只读核对 schema、nullable `entry_mode`、`STAFF/ADMIN` 约束，并记录 `SELECT count(*) FROM identity_admin_sessions WHERE entry_mode IS NULL`（旧会话须重新验证）。 | 迁移失败、超时、0092 结构不符或旧 NULL 计数无法解释：停在原地，检查私有日志及实时 schema；不重复迁移、不切服务、不降级数据库。 |
| 3. 候选切换 | 执行 `python3 server_release.py deploy`；其切前再次验证 0092、迁移/克隆证明、最终双源 Compose 与候选/回退 API **9/9**、Worker **8/8**。仅 API 切到 `0bdf751c…`，Worker 保持 `3c9e4bbf…`；API healthy 后全量预检并发布 18 静态 SHA，`admin.html` 最后。`download.html` 不在范围。 | 双角色证明、健康或任何静态预检/写后 SHA 失败：发布器自动尝试下述兼容回退；不得手工绕过门禁。 |
| 4. 双端验收 | 执行 `python3 server_release.py verify`；服务器 `python3 public_verify.py`，工作站经既有 jumper SOCKS 运行同一脚本 `--socks5-hostname 127.0.0.1:<已建立端口>`。两端须严格验证 TLS、JSON ready、无凭据 `/api/v1/admin/context` 为 401、18 个静态响应 SHA；并核 API/Worker image、healthy/restart count、0092、其他 27 容器名称/ID、发布后错误/Traceback 日志计数。仅记去敏结果及证据路径；匿名探针不等于真实管理员业务验收。 | 任一健康、TLS、401、静态 SHA、容器 ID 或异常日志检查失败：按回退门禁处理并保留现场证据。 |

**0092 后回退。** 仅用 `python3 server_release.py rollback`。它先核对 manifest、备份、0092、静态与两个最终 Compose、候选/回退 API 9/9 和 Worker 8/8、唯一受控 API 入口；随后停该入口、事务性撤销 `identity_admin_sessions` 关联的全部活跃 refresh family，先撤新 `admin.html`，恢复其余静态，并切到 0092 兼容 API `c5e1fe41…`，确认 healthy 与其他容器不变。停 API 期间整个 Business API 短暂不可用，管理会话被注销；**不恢复生产数据库、不降级 0092**。若回退前置门禁本身失败，停止自动操作并由 root 根据私有现场证据处置，不能强切旧 0091 API 镜像。
