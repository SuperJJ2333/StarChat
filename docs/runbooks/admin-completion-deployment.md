# 管理后台完整交付与受控人工修复发布

适用：2026-09-10后台账目筛选与用户资料、链上/事故详情弹窗及受保护的人工资金修复入口。发布不等于执行充值、提现、事故结案或任何自动资金操作。先读 [admin-production-workflow.md](admin-production-workflow.md)；权限、幂等、链证据、钱包二次验证及最终提交前校验继续有效。

## 已冻结的本次发布范围

| 项目 | 精确记录 |
|---|---|
| API基线/回退镜像 | `sha256:0616ae88702a68c9b98a35e2da8a186727162f5eca8d434f61303012e10e8166` |
| API已部署镜像 | `sha256:84edda0271dae31b71a74f0d3c1fbff3112bcd4e263c6f3e859767b6d2e3c5d8` |
| Worker保留镜像 | `sha256:7e0e9ffc64c670bf5f144c50357861f9345fa36b7b3236039700e4970823d534` |
| Schema | `0063_merge_wallet_access` → `0064_admin_deposit_repairs` |
| 服务器发布目录 | `/opt/starchat/releases/admin-completion-20260910/` |
| 手工修复开关 | 代码默认false；本次冻结API配置明确设置 `BUSINESS_WALLET_MANUAL_REPAIRS_ENABLED=true` |

上述为本次发布事实，不是后续任务可以直接复用的当前基线。新的发布或回滚必须先重新读取运行镜像、容器ID和配置。API已部署摘要显示healthy、RestartCount=0；迁移摘要将镜像与0064及实际表校验绑定。原有Worker、网关和其他容器不在重建清单内。

## 连接与准备

默认 `ssh -J jumper -p 23421 root@207.56.8.8`，优先通过 `scripts/starchat-server.ps1 -Action Command`。保留host-key/TLS验证。服务器发布目录保存真实环境、原Compose文件、数据库dump及回退配置，目录0700、敏感文件0600；不将完整目录下载到仓库或输出环境变量。

任务专用工具的工作区副本位于 `docs/verification/artifacts/2026-09-10/admin-completion/production/`；服务器使用发布目录中的 `server_release.py`、`rehearse.py`、`migration_gate.py`、`static_release.py`。静态/API文件集合及SHA256以 `source/manifest.json` 为准，不从整个工作区覆盖生产。API候选基于上述0616镜像增量构建，构建禁止拉取和网络访问。

首次发布的顺序如下，已经存在的初始证据不能覆盖：

1. `python3 /opt/starchat/releases/admin-completion-20260910/server_release.py snapshot`：冻结实际API配置和其他容器ID，生成精确回退配置，比较环境、命令、挂载、网络、隔离及健康检查。
2. 同工具依次执行 `build`、`backup`：核对源文件manifest、产生不可变候选digest、生成数据库dump及SHA256。
3. `python3 /opt/starchat/releases/admin-completion-20260910/rehearse.py`：候选/回退配置及导入检查；在隔离PostgreSQL恢复dump，先验证0063，再演练0064扩展迁移。隔离容器按任务标签校验后清理。
4. `python3 /opt/starchat/releases/admin-completion-20260910/static_release.py preflight`：逐文件静态基线与备份，保留下载页、首页和admin-session.js的原摘要。
5. `python3 /opt/starchat/releases/admin-completion-20260910/migration_gate.py`：要求恢复、候选和运行基线证据一致，用独立候选迁移进程将真实库升级至0064，检查新表存在并写入绑定候选digest的migration-proof。
6. `python3 /opt/starchat/releases/admin-completion-20260910/static_release.py deploy`：重新检查真实schema、基线镜像和运行配置，使用冻结Compose仅切换API并等待健康；随后逐文件原子安装静态内容，admin.html最后安装。错误进入静态/API回退。

0064新增 `wallet_repair_previews`、`wallet_repair_commands` 及append-only保护/唯一约束。它不修正现有账本、不改变历史订单时间，也不执行业务资金修复。生产切换只接受 `0064_admin_deposit_repairs` 和两个新表同时存在的实测结果，不能仅凭旧proof文件跳过查询。

## 发布验证与时钟边界

执行 `python3 /opt/starchat/releases/admin-completion-20260910/static_release.py verify`，核对API完整配置、候选digest、健康、其他容器ID和静态SHA256。公网API探针使用 `https://liuhetong888.com/api/v1/health/ready` 的JSON200及未登录管理接口401；后台静态哈希使用 `https://admin.liuhetong888.com/`。工作站和服务器分别验收，不以www的HTML200替代API健康。

人工修复入口启用后仍必须取得真实业务证据、操作人授权、钱包验证、有效预览及最终确认。ClockHealth对两份独立HTTPS Date测量作失败关闭判断；偏差、分歧、超时或不新鲜时拒绝新例外命令，不放大容差、不缓存确认凭据、不自动重放失败请求。

本次另行部署的chrony主机纪律见 [ADR 0067](../adr/0067-production-clock-discipline.md)。其首次timer过密问题已通过中性drift恢复、maxdrift 500和最短300秒间隔修正。clock发布目录为 `/opt/starchat/releases/clock-20260910/`，工具为 `scripts/starchat_clock_release.py` 的prepare/start/recover-frequency/rollback模式及 `scripts/starchat_clock_feed.py`；不要把一次性的recover-frequency当成周期任务。时钟恢复与API部署分别保留证据，不能把当前偏差推定为所有历史交易的偏差。

## 回退

先确认当前API和静态文件仍属于本次候选，且没有后续任务发布；否则先取得新交接，禁止旧工具覆盖新版本。

执行 `python3 /opt/starchat/releases/admin-completion-20260910/static_release.py rollback`，恢复逐文件备份和0616 API冻结配置。新增但旧页面不引用的静态文件允许保留。API-only场景可使用 `server_release.py rollback`。两者都不重建Worker，不恢复生产数据库dump，不降级schema；0064的新表、幂等记录及审计必须保留。数据库dump用于灾难恢复流程，不能用来撤销一次正常API发布。

需要只关闭人工修复入口时，基于最新API运行配置生成并核验仅将 `BUSINESS_WALLET_MANUAL_REPAIRS_ENABLED` 改为false的覆盖，再按发布流程应用；不能直接复用过期Compose、覆盖其他配置或假称无需重建API。

主机clock回退独立执行：停止/禁用feed timer，停止custom chronyd，仅恢复timesyncd原开机偏好并保持停止，待安全对时策略重新评审后再启动。不得恢复错误墙钟；NTP恢复网络时timesyncd可能step，因此不能无条件启动它。金融例外健康守卫继续保留。

服务器可公开摘要证据为 `images.json`、`postdeploy-summary.json`、`migration-proof.json`、`backup-summary.json`、`restore-proof.json`。完整baseline、环境、数据库dump和业务敏感明细仅留受限服务器目录。
