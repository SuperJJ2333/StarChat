# 业务续期发布门禁与邮件监控

适用于 business-api/business-worker 的发布、故障恢复与回退。续期协议基础为 ADR-0080；角色化镜像检查依据[已批准的 ADR](../adr/2026-09-28-role-aware-refresh-image-gate.md)。门禁只验证镜像内协议与运行路径，不改变鉴权策略、会话期限或金融逻辑。

## 发布与回退

**截至 2026-09-28 17:41 UTC：获批的角色化 guard/probe 已安装在服务器，SHA256 分别为 `78b2beb6c20484cea04fa8e77c1dd23b9a3e401af9d6fafd3e4b7d316d07beec`、`d77a83e89d848bfc8b6d7dad72b9abd01d60550a6e356d0a12b382674c37b678`；旧版私有备份位于 `/opt/starchat/releases/role-aware-guard-20260928-d0_vhuqs`。独立 r2 恢复候选与回退 API/Worker 镜像已逐角色通过门禁，r2 已仅切换 API 至 `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`，Worker 保持 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，schema 仍为 0091。** 管理台 A1–A5 已在恢复后基线冻结新候选，截至此时仍未发布；每次切换仍须对其最终候选与回退镜像重新做双角色证明。以下角色化命令须在逐文件 SHA 核对与生产预检后使用。禁止把 0.4.6 协议缺失的旧镜像当作正常回退目标；恢复基线以当次生产证据为准。

旧发布 `/opt/starchat/releases/refresh-restore-20260924/release.py` 的 deploy/rollback（包括失败回退）曾调用 `business_release_guard.py freeze`，核对 Compose 与镜像后冻结配置；它硬编码 schema 0087，不能用于当前 0091。历史 `check --image` 命令也不满足新双角色证明，受控新门禁改用 `--api-image` 和 `--worker-image`。新 `freeze` 仅适用于具有两角色 `images.json` 或 `rollback-images.json` 和对应单服务私有 Compose 的发布目录；管理台受控发布器使用显式 `check` 与 `deploy/rollback`。

角色化探针在最终不可变镜像中运行，无网络、只读根文件系统、移除全部 Linux capabilities、禁止提权；只传合成测试配置与内存 SQLite，不挂生产密钥或数据库。API 角色固定导入 `/opt/business-api/app` 并运行真实 ASGI 的 **9 项**：过期 access token 与刷新、无敏感回显的参数校验、相同操作的确定性结果且不延长过期时间、刷新后业务端点可用、超前结果拒绝、登出隔离与撤销、错配重放撤销 family、旧式严格轮换、管理员域与 Cookie 边界。Worker 角色固定核对 `/opt/business-worker/app/{main.py,tasks/identity.py,tasks/wallet_alert_email.py}` 与 `/usr/local/lib/python3.12/site-packages/app` 的真实导入来源，并执行 **8 项**：导入来源、凭据事件注册、安全字段拒绝、精确 T2 源读超时为 advisory 且不自动暂停、相同刷新结果不延寿、超前结果拒绝、错配重放撤销 family、旧式严格轮换。Worker 的告警处理模块只核对导入来源；实际邮件投递由独立 Worker/T2 测试证明。Worker 不提供完整 API ASGI 路由，因此不能用旧 `/opt/business-api` 副本的 API 九项检查代替其运行路径检查。

候选与回退的 API/Worker 镜像都必须以不可变 `sha256:` ID 明确标注角色。即使候选与回退 Worker 是同一镜像，仍应在清单中分别记录，两角色证明均不可缺少。`check` 缺任一角色即拒绝；`deploy/rollback` 即使只重建 API，也必须同时提供两份 Compose，先验证两个角色，再冻结实际渲染配置。示例中的镜像 ID 与路径须换成已复核的当次值：

```sh
python3 /opt/starchat/ops/refresh-guards/business_release_guard.py check \
  --api-image sha256:<candidate-api> --api-image sha256:<rollback-api> \
  --worker-image sha256:<candidate-worker> --worker-image sha256:<rollback-worker>
python3 /opt/starchat/ops/refresh-guards/business_release_guard.py deploy \
  --compose /绝对路径/candidate-api.json --compose /绝对路径/candidate-worker.json \
  --service business-api
python3 /opt/starchat/ops/refresh-guards/business_release_guard.py rollback \
  --compose /绝对路径/rollback-api.json --compose /绝对路径/rollback-worker.json \
  --service business-api
```

需要沿用 `freeze` 的其他受控发布器须提供分别含 `api`、`worker` 镜像 ID 的 `images.json`（候选）或 `rollback-images.json`（回退），以及同目录下相应的 `candidate-{api,worker}-private.json` 或 `rollback-{api,worker}-private.json`，分别执行 `freeze --release-dir /绝对路径/发布目录 --version candidate` 和 `--version rollback`。每份 Compose 只能含对应角色的单个服务，镜像 ID 必须与清单一致；管理台受控发布器不调用 `freeze`。

`--service` 只选择实际重建的服务，不缩小镜像检查范围。门禁仅接受精确角色、协议及断言列表，任一失败先于冻结配置或切换。它保存权限受限的冻结 Compose，转义字面 `$` 后执行 `up --no-deps --pull never --no-build`。发布器还必须绑定 guard 与 probe 两个文件的 SHA，重冻目标静态与镜像源码、Compose、schema 和其他容器，完成数据库兼容性、隔离恢复、健康及公网 HTTPS 验证。门禁证明不能代替完整发布验收。

安装新 guard/probe 前，分别私有备份现行字节、权限和 SHA；安装后校验新 SHA，并对候选及回退 API 九项、Worker 八项实际不可变镜像检查。业务镜像回退仍保留新门禁以验证两角色；旧门禁备份只用于另行审阅的门禁恢复。主机 root 直接运行 Docker、改写运维脚本或使用未接入的旧 release.py 仍可绕过门禁；禁止这样发布。此门禁是受控发布入口，不是宿主机权限隔离机制。

## 邮件配置位置与检查

复用现有`starchat-business-worker-1`环境配置中的`SMTP_HOST`、`SMTP_PORT`、`SMTP_FROM`、`SMTP_USERNAME`、`SMTP_PASSWORD`、`SMTP_SECURITY`及`SMTP_TIMEOUT_SECONDS`，以及`BUSINESS_WALLET_ALERT_RECIPIENT`，由已有`integrations.email_sender.SmtpConfig`读取。`SMTP_DELIVERY_ENABLED`必须启用，`SMTP_SECURITY`必须为ssl或starttls。运维脚本不复制密码、不回显收件地址。变更邮件配置按worker现有Compose环境来源管理，不把密钥写入本仓库。

主机代码：`/opt/starchat/ops/refresh-guards/`。监控状态：`/var/lib/starchat-refresh-watch/state.json`（0600）。systemd配置：`/etc/systemd/system/starchat-refresh-watch.service`、同名timer及`starchat-refresh-watch-failure.service`。

检查命令：

```sh
systemctl status starchat-refresh-watch.timer
systemctl show starchat-refresh-watch.service -p Result -p ExecMainStatus
cat /var/lib/starchat-refresh-watch/state.json
```

状态仅有计数、原因码、事件ID及时间，不包含原始请求或令牌。需要验证投递时由授权运维执行一次：

```sh
python3 /opt/starchat/ops/refresh-guards/refresh_watchdog.py --test-email
```

只有`SMTP_ACCEPTED`表示SMTP服务器接受，不能断言已进收件箱。主题“登录续期监控：通道验证”。不重复发送测试邮件。

## 告警语义与边界

每分钟检查最近5分钟：422或5xx各达3次；总请求至少10次且非2xx比例达20%；无效令牌协议探针失败、日志截断或监控检查失败。日志上限20000行/4MiB，探针使用合成无效令牌，不产生真实会话，其401不进入错误率。401比例包括真实会话失效，因此告警表示需要调查，不等于已确认系统故障。

同原因每5分钟最多一次成功通知；新增原因单独通知，恢复另发邮件。发送失败保留事件ID，以60/120/240/300秒退避；只维护一个待发事件并合并当前状态，因此长期SMTP失败期间的短暂状态不保证逐条保存。进程在SMTP接受后、状态保存前崩溃可能重复投递，稳定Message-ID便于识别。SMTP不可用时不会伪称告警已送达；检查delivery_error、pending及systemd失败状态。

线上探针检查请求协议兼容，隔离镜像测试覆盖真实轮换；两者不代替真实用户跨客户端端到端监控。宿主机宕机或SMTP整体不可达仍需要独立外部监控。

## 安装恢复

安装脚本只修改上述运维文件和已明确指定的release.py，保存修改前文件、权限、哈希及timer状态，不重启业务容器。备份留安装目录`install-backup-*`，使用`install_refresh_watchdog.py --restore-backup /完整备份目录`可恢复；先校验所有目标，发现后续修改则拒绝覆盖。重复恢复安全。恢复只撤回本任务运维接入，不回退已修复的业务镜像。
