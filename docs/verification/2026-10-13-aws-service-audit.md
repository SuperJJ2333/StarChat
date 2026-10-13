# AWS全主机服务检查（2026-10-13）

检查窗口20:27–20:33（+08），目标新加坡AWS 18.143.207.225，实例c5.large。用户称修改配置，授权检查所有服务；本次仅只读诊断，未重启、部署、删除历史容器或改变安全组。证据为当次实时采集，不用10月12日发布快照代表当前状态。

## 当前结果

| 范围 | 实测结果 |
|---|---|
| 主机 | 20:16:32重启；可用内存3061MiB/3793MiB，根盘9.2/40GiB（23%），inode1%；当前可用journal窗口无OOM/I/O错误匹配 |
| Docker | 8个现役容器全部running，6个有healthcheck全部healthy，现役RestartCount均0/OOMKilled=false，全部unless-stopped |
| CoScene | api/edge/postgres健康；Redis认证PING PONG，PG按配置用户/database探测可连接；CloudFront首页200/API health200且JSON ok=true |
| GA Gold | runtime健康、edge运行；本地TLS及CloudFront首页200（未执行登录/游戏写入流程） |
| ChatFlow AWS边缘 | nginx配置检查0、内部health200、合法www SNI转发200；coturn健康、UDP STUN binding成功（未验证完整认证TURN分配/双端通话） |
| 系统其他服务 | 23个运行服务；系统及ec2-user级failed均0；Docker/SSM/CoScene私有隧道enabled；隧道running且NRestarts0/近期错误匹配0；9项timer已列出 |
| CloudFront | 4个distribution均Enabled/Deployed；CoScene和GA Gold入口实测通过 |

## 异常、风险与建议

1. **P2 发布窗口短暂断流**：CoScene edge于20:22:15–16有3次connection refused，与API新实例20:22:15启动相邻；最后5分钟该错误0。建议后续API发布先通过readiness再切上游，并验证切换无502。未将历史错误隐去，也不据此断言所有请求无失败。
2. **P2 CoScene日志容量风险**：api、edge、redis、postgres的json-file LogConfig为空，未见容器级max-size/max-file。建议在其所属部署配置加入例如10m×3轮转，再按维护窗口逐个重建并验收；不要现场清空日志或为了设置轮转打断数据库。目前磁盘充足，无紧急清理需要。
3. **P2 健康检查覆盖缺口**：coscene-redis与ga-gold-aws-edge未配置Docker healthcheck。本次用实际PING及HTTPS补验；建议把对应探测纳入持久健康检查/告警。
4. **P2 历史容器治理**：43个停止容器名称均为before/rollback/pre-v2历史版本，不能因旧容器保留unhealthy字段就判定现役服务故障。部分旧容器exit137且OOMKilled=false，不能推断OOM。保留回退副本，由所属项目确定保留数量后再清理。
5. coturn启动出现no-cli弃用提示，当前健康及STUN通过；可在后续版本维护替换弃用选项。

## 网络限制与证据边界

- 安全组18443/28443只允许CloudFront前缀列表pl-31a34658，所以普通公网直连超时符合回源限制。CoScene本地TLS不携带origin/gateway凭据返回403，配置确有对应guard；正式CloudFront入口200。没有放开安全组或绕开鉴权。
- `https://sg.liuhetong888.com:443`不在ChatFlow SNI映射，直探连接重置；使用配置中的www.liuhetong888.com SNI成功。猜测的ChatFlow `/health/live`路径404不等于服务停机；本地既定health路由200。最初猜测CoScene容器`/health`404，随后实际执行配置的healthcheck退出0、公开`/api/health`200。
- 首次无用户参数pg_isready虽然返回可连接，却额外产生一次默认角色不存在日志；已按容器既有用户/数据库重测通过，此探测副作用不计为产品故障。重启前3条管理员终止连接及1条数据库关闭日志已归因。
- EC2 describe-instances可读，describe-instance-status退出254，未获得AWS系统/实例状态检查结果；不宣称AWS两项状态检查通过。containerd unit disabled但进程运行，Docker开机启动已启用，不能仅由disabled判断故障。
- 未获得用户具体配置差分，不能判定所有改动正确；未执行CoScene播放/登录、GA游戏事务、完整TURN通话、全互联网地区/持续负载测试。本次结论是当前主机、现役服务及所测入口正常。

## 证据

[主机快照](artifacts/2026-10-13/aws-service-audit/snapshot.json)、[服务深入检查](artifacts/2026-10-13/aws-service-audit/deep.json)、[正式入口与STUN](artifacts/2026-10-13/aws-service-audit/final.json)、[安全组及JSON健康](artifacts/2026-10-13/aws-service-audit/security.json)、[系统timer与用户服务](artifacts/2026-10-13/aws-service-audit/host-final.json)。原始应用日志仅在服务器内聚合，未导出正文/凭据。
