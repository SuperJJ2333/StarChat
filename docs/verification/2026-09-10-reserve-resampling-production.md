# 钱包有界重采样生产部署证据

2026-09-10 用户追加授权部署后执行。主机时钟偏差约 +58 秒，以下服务器时间仅作为日志定位，不当作精确外部 UTC。

## 结果

仅更新 business-api、business-worker；运行健康、重启计数 0，其他容器 ID 不变。代码摘要与实际导入路径校验通过。Worker 预算 60；管理员同步短重采样不变。

| 服务 | 原镜像 | 新镜像 |
| --- | --- | --- |
| API | sha256:b895ff3217a169bb3e1f4a03004c5cf9da45d0ef57d284894587f36dedf3120b | sha256:0d330c6e2172c637b28fca9d788ea511b718af6698cbf904570257dfe6f4a839 |
| Worker | sha256:27bc9f7de31fb5803e3180e6817e319cced9fc1462379146ddf1dc4350925eb5 | sha256:3cf135766777f807f6d5df88c81baf20c24076b3a07577e7d75768bf50385aa2 |

生产 schema 为 0059_chat_payment_pin。发布前后 withdrawals_paused=false、pause_reason=null；MANUAL_SOURCE_UNHEALTHY 保持 RESOLVED，既有 MANUAL_BACKING_DEFICIT 保持 ACKNOWLEDGED。这些是实时只读结果，与用户引用的较早事故状态不同。本次没有执行确认、结案或恢复资金命令。

## 发布与验证

- 本地完整门禁已在本次实现记录中通过。发布脚本另有 13 项离线故障测试通过，覆盖停止失败回退、配置漂移、特殊字符、秘密输出和无关容器保护。
- 45,379 字节代码归档 SHA256：6b11f0358e0ef479805ba7699441234fcb6b8e3f7279b36051909d025921563e；服务器校验后解包。API 保留生产独有 payment_pin 配置，未整包覆盖工作区。
- 生产配置与数据库只留在服务器 0700/0600 发布目录 `/opt/starchat/releases/reserve-resampling-20260910/`。数据库备份 SHA256：9250f172ae426c2a32eee18e6dc45711977477b4ddd106a1cef2ec88b64f7003，2,277,142 字节。
- 候选/回退 API/Worker 四组临时容器仅创建、不启动；环境、命令、挂载、网络、端口、完整健康检查、日志及安全/资源设置与原容器比对通过。唯一环境差异是 Worker 预算。
- 候选镜像断网导入校验通过。数据库在独立 `--network none` PostgreSQL 中恢复成功，版本与实时生产 0059 相同；未向生产还原备份。
- 停止旧 Worker 后先 API、后 Worker 切换，均健康；未触发回退。postflight.py 验证镜像、运行配置及其他容器 ID。
- API/Worker 每个修复文件哈希和实际 Python 导入路径均通过；Worker 从安装目录导入的新代码已确认，不仅核对源码目录。
- 服务器及工作站：正确 API 域名健康 JSON 200，未登录更新查询 JSON 401/AUTH_REQUIRED。最初检查 www 返回静态 HTML 200，已识别并更正，未将其当作 API 通过证据。
- 上线约 6 分钟观察已记录 6 次 PUBLISHED 维护结果；最近成功心跳 22:23:55（服务器时钟）、last_error_code=null、告警配置为真；源健康、observation_id 从 8018 推进至 8027。没有观察到新源阻断。等待分支并未人为在生产注入故障触发，其故障恢复能力由先前隔离测试证明。

初次配置解析缺失插值 TRON_WATCH_DATA_DIR，后从实际只读挂载获得并严格比对；初次创建命令包含本机 Compose 不支持的 --no-deps，移除后重试。首次恢复探针过早命中初始化过程，改为 TCP 数据库查询；恢复版本断言从历史 0055 更正为实时 0059。所有问题均在生产切换前解决，最终演练通过。

临时容器均已移除。恢复容器先前移除未带 -v，匿名恢复卷可能保留在服务器；事件记录未能可靠关联卷归属，未按 dangling 标记执行全局删除。数据库备份及这些可能的恢复副本仍属服务器受限数据，不向工作区复制。

## 未解决的时间问题

独立只读核查：Google、Cloudflare、Microsoft HTTPS Date 的 RTT 中点估算分别约 +58.713、+58.801、+57.973 秒；timesyncd 未同步，最近两小时 54 条超时且无同步记录。它强烈支持约 58 秒快钟，但不是精密对时，也不能证明 UDP 单方向封锁或逐次历史事故的全部因果。

本次未修改时钟/NTP/防火墙。代码部署不解决时间偏差，后续应单独恢复可靠对时；不承诺事故永不复发。回退与维护步骤见 docs/runbooks/wallet-reserve-resampling-deployment.md。

脱敏工件：docs/verification/artifacts/2026-09-10/reserve-production/；完整生产配置/数据库不在其中。
