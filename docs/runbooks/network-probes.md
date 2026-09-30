# 双区域观测与真实用户日志

本轮依据：[已批准设计](../superpowers/specs/2026-09-26-regional-measurement-design.md)、[任务记录](../workflow/tasks/2026-09-26-regional-measurement.md)。用户暂时没有独立测点，主要依赖下一次客户端更新后的真实请求摘要；本轮源码完成不代表采集已上线，不启动主区迁移。

## 真实用户口径

新客户端在已认证诊断scope内，透明观测业务HTTP每次尝试，耗时到响应体消费结束。完整2xx、3xx、4xx、5xx、网络错误、超时、取消分开计数，和为attempts。401/403是HTTP响应，不是线路不可达。自动重试的每次实际HTTP尝试分别计数，因此不能把attempts当用户动作或活跃用户数量。

成功2xx的固定非累计耗时桶为≤100/250/500/1000/2000/5000/10000/30000ms和>30000ms。报告p95/p99是命中桶上界，不是精确百分位数；超出最后桶没有有限上界。失败请求不塞进成功耗时分布，单独显示网络失败率、5xx率和响应率。

每个不可变摘要含随机sample_id、来源版本/platform与UTC起止窗，失败重试复用ID；离线汇总按ID去重，重复ID内容不一致则拒绝报告。不收集用户/房间标识、IP、位置、运营商、SSID、URL、正文、金额或凭据。network仅为连接方式，不等同于运营商或地理位置，VPN/透明路由也不能据此排除。

只有完成且进入有界队列的已认证尝试能被观测；未登录、未消费响应、进程退出、队列超限、长期无法上传都可能造成缺样本。spool是尽力补报，不是完整事故账本；旧schema1没有原版本/时间，本轮客户端全部丢弃并计入本地droppedSpoolBatches，不能重新标成新版数据，见[诊断手册](client-diagnostics.md)。无数据不等于无失败。

发布顺序：先兼容接收端，确认16KB/鉴权/限流/日志轮转；再将客户端源代码增量包含在下一更新。旧接收端422时客户端停用网络扩展，按既有节奏继续原通道。只有确认生产收到包含新networks的真实数据时才记录观察起点，持续7–14天并覆盖晚高峰和周末。

## 安全收集与报告

所有命令在仓库根执行。Windows用PowerShell7，先设置UTF8无BOM的console/pipeline和PYTHONUTF8=1/PYTHONIOENCODING=utf-8。以下路径按实际执行日修改；输出只能位于docs/verification/artifacts下。

```powershell
py -3.12 scripts/collect_network_diagnostics.py --since-hours 72 --tail 20000 --output docs/verification/artifacts/2026-09-26/regional-measurement/user-network-collection.jsonl
py -3.12 scripts/network_report.py docs/verification/artifacts/2026-09-26/regional-measurement/user-network-collection.jsonl --output docs/verification/artifacts/2026-09-26/regional-measurement/user-network-report.json
```

收集器使用既有`starchat-server.ps1`/jumper，远端只读固定业务API容器日志，先过滤/校验闭合摘要，再输出网络元数据；禁止直接下载docker logs、inspect环境或未脱敏日志。回溯时间最多72小时，行数最多100000，单行最多64KiB，导出最多16MiB/20000个摘要，远端读取最多60秒。扫描上限、截断、有效/拒绝/缺失样本另存`.meta.json`；达到tail或导出上限会明确标注覆盖不完整。`rejected_lines`也包含非目标事件和不符合导出结构的日志，不是请求失败次数。

同一文件名再次运行会替换本次快照；持续观察需采用独立时间戳文件名，累计汇总时让sample_id去重。`--since-hours 72`只是读取条件，日志轮转和tail上限可能使实际窗口更短，不能据此声称获得完整72小时。上线后先核对实际日志速率/留存，再设置足以覆盖观察窗口的采集频次。报告输入也只应来自此收集器或探针，而非原始用户日志。

## 独立HTTPS探针

若后续获得真实测点，可同轮交替请求两个明确公开目标；没有对照服务的节点不算候选业务主区。

```powershell
py -3.12 scripts/network_probe.py --target hk=https://liuhetong888.com/api/v1/health/ready --vantage known-probe --country unknown --carrier unknown --network unknown --count 10 --interval 60 --timeout 10 --expect-json database=ready --output docs/verification/artifacts/2026-09-26/regional-measurement/public-probe.jsonl
py -3.12 scripts/network_report.py docs/verification/artifacts/2026-09-26/regional-measurement/public-probe.jsonl --output docs/verification/artifacts/2026-09-26/regional-measurement/public-probe-report.json
```

`--target`最多8个、唯一名称；次数1–1000，间隔0–3600秒，单次超时1–60秒，无自动重试。HTTPS证书验证不关闭、不跟随重定向、禁用curl配置文件和环境代理、响应最多16KB；无认证。普通200页面不代表API健康，用`--expect-json database=ready`验证公开健康JSON（现有契约为ok=true、database=ready，并没有status字段）。

`--address hk=207.56.8.8`保留域名/SNI并强制指定IP，但绕过DNS，所以dns_ms=null并标记dns_bypassed。系统TUN、透明代理仍可能存在；不得把`--noproxy`当作已证明真实运营商路径。报告按DNS绕过/代理/路径标记分组，不能混算。

每条保留成功/失败分母及UTC时间、DNS/TCP/TLS/TTFB/total；未完成的阶段为null。标签均为操作员声明，未独立验证。服务器自身、jumper和工作站路径必须分组，不得与大陆三网或东南亚用户直接比较。

## 主区决策缺口

真实用户摘要目前只标primary_api和连接方式，无法识别地区、运营商或实际香港/新加坡路由，也未覆盖Matrix同步、消息对端显示、媒体完整链路和TURN通话。现有单一主站日志只能建立现状基线，不能证明另一主区更稳定。

报告固定返回`evidence_insufficient`，不会根据平均ping或少量成功请求选主区。还需两地相同软件/相当资源/代表性负载的完整候选、地区分组及故障恢复演练。新加坡边缘回源香港的测试只评估接入路径，不能证明香港源站故障时仍能业务存活；主区/S3/DNS变更按独立方案执行。
