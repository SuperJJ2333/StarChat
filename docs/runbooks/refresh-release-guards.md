# 业务续期发布门禁与邮件监控

适用于2026-09-24后的business-api/business-worker发布、故障恢复与回退。协议基础为ADR0080；不改变鉴权策略、会话期限或金融逻辑。

## 发布与回退

必须先在最终不可变镜像执行实际ASGI协议测试，不能用源码测试或health 200代替。API和worker全部通过后才可切换。禁止把0.4.6协议缺失的旧镜像当作正常回退目标；恢复基线见当次生产证据。

已接入的生产入口为`/opt/starchat/releases/refresh-restore-20260924/release.py`的deploy及rollback（包括部署失败调用的rollback）。它调用`/opt/starchat/ops/refresh-guards/business_release_guard.py freeze`，核对实际Compose服务镜像与清单一致，测试所有镜像后冻结配置，启动时使用该配置。冻结时转义字面量美元符号，保留原有环境值。

未来发布入口必须使用同一门禁：先用`check --image sha256:...`作候选预验收，实际切换使用`deploy --compose /绝对路径/配置.json --service business-api --service business-worker`；回退用相同参数的`rollback`。该命令保留私有冻结配置，执行`up --no-deps --pull never --no-build`。切换后的健康检查、必要的数据库兼容性验证和恢复方案仍须执行。该门禁只证明续期协议，不能代替完整发布验收。

主机root直接运行docker、改写运维脚本、历史未接入的release.py仍能绕过；禁止这样发布。这是受控发布入口，不是宿主机权限隔离机制。

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
