# 网络稳定性与全链路诊断修补：方案任务记录

## 恢复入口

- 目标及授权：用户2026-09-26明确批准“完成修复方案后，推送debug版到模拟器安装”。执行本方案的客户端、探针与 API 最小增量修补，并保留数据覆盖安装雷电 Debug；不切换业务节点池，不发布正式 Android/iOS 安装包。
- 设计：[网络与诊断修补](../../superpowers/specs/2026-09-26-network-diagnostics-remediation-design.md)；计划：[分工作包实施](../../superpowers/plans/2026-09-26-network-diagnostics-remediation.md)。
- 现有事实：[只读审计](../../verification/artifacts/2026-09-26/network-coverage-audit/findings.md)；已完成基础任务：[TCP与暂存](2026-09-26-netmon-tcp-diagnostics.md)。禁止把旧部署历史当实时状态。
- 当前状态：源码/专项和完整 Flutter 门禁通过；NETMON 两点已安装验收，API r4 cf7c4926…已受控发布、健康/零重启且真实request/SQL关联通过。Debug `0.4.13+2180` 进入固定签名重建安装。基线971fb50d193ab1a34610bd7908c2dbf6272db431，分支 `codex/network-diagnostics-remediation`。
- 工作树：`C:/Users/Administrator/.codex/worktrees/merge-main-20260926/StarChat`；root 拥有 core trace/model/metrics、call/search/room_page 和交付文档；独立 agents 拥有诊断队列、Matrix/Outbox 接线、netmon 和 API，文件顺序交接。原main WIP保持。
- 最后更新时间：2026-09-26 19:22香港时间。
- 下一条操作：提交已验证冻结源码，按固定签名重建2180并保留数据安装雷电，回读Dart四位build/diagnostic VM与安全网络状态。
- 必要外部输入：13节点真实SSH用户/端口及云控制台权限、目标用户地区/运营商；审计已发出问题，尚无答复，分别阻断N01或N04，不阻断其他工作包。

## 验收台账

| ID | 目标 | 当前状态 |
| --- | --- | --- |
| N01/N02 | 次节点入口与雷电路径恢复/定位 | 13 SSH22仍未到认证，待外部入口；雷电同窗HTTPS4/4成功92–103ms，宿主机4/4 TLS失败，机制未确认 |
| N03/N04 | 有界旧探针与完整区域稳定性 | 52专项及infra224通过；Linux/Windows两分钟以上真实调度通过，原443不变；24h/7d和多运营商未取得 |
| C01/C02 | 同根多记录不丢与在途/超期可见 | v3 entry身份、partial索引、checkpoint/expired、100并发联合71通过；待最终装机 |
| C03/C04 | 会话/发送重试与准确网络/帧证据 | B3 220、最终echo58、sync43通过；真实错误、每cycle Watchdog增量、35s正常poll不误判；专项analyze零问题 |
| C05/C06 | DB媒体通话与摘要统计口径 | 实际media-index SQL、单调时钟代表通话样本、setup关联、每次搜索、语义分桶专项通过；未测SDK阶段保持unsupported |
| S01/S02 | 生产request/DB hooks与严格协议 | 最终226通过1PG条件skip；r4 isolated/production真实2worker HTTP/SQL通过，19:13 guard切换exit0、healthy/零重启/38其他容器不变；备份恢复137表/schema0088通过 |
| R01 | 新四位Debug包与正式两端能力对齐 | build2180冻结/合同3通过，完整analyze No issues0/Matrix2180/full4549均0、9条件skip；构建安装待执行，正式两端未发布 |

## 版本与证据

- 雷电审计时：com.liuhetong.mobile.debug，0.4.13/2179；新31efd61f本地暂存和network_request未进入该包。
- 源码：971fb50d；运行API审计时digest ea950a2f…，只升级receiver。下一次操作必须重读真实运行镜像。
- 最终汇总及所有实际门禁出口：[交付验收](../../verification/2026-09-26-network-diagnostics-remediation.md)。首次全量analyze发现sealed父类6个override annotation info，修正后 `No issues found` exit0。verify.ps1真实exit1（缺.env）；infra224、mobile238/1skip、UI合同/import/Compose、AST270、Alembic头/离线生成均exit0。未完成的全量/装机门禁不冒称通过。

## 阶段与交接

- 规划阶段开始精确墙钟未保留；07:30:45UTC（15:30:45香港时间）有clock读数，文档核查结束为15:39:57香港时间；不把两读数之差称为完整规划耗时或实施耗时。
- 网络、客户端与API各有独立实现/专项及规格→质量安全复核。额外审查发现准备期间合法echo随后异常会误记failed、真实include_router快照未保留关联，两者已有真实RED/GREEN并在候选验证，不放宽隐私过滤。
- 已修复问题：旧探针无限等待/缺测、未完成trace盲区、视频首次finish抹去重试观察、spool同根去重及ACK身份风险、通用Timeout误标phase、通话末次健康遮盖尖峰、Matrix sync丢真实错误与本轮Watchdog增量。
- 尚未确认：雷电具体网络设备/运营商故障机制、13节点安全组或实例状态、媒体各不可拆阶段真实耗时。
- 回退：Linux/Windows旧探针及私有manifest已备份。API candidate/rollback只差image，旧/新/worker续期门禁及数据库备份恢复通过；只有健康发布失败时才按漂移守卫回退。没有把准备回退命令称为执行了完整回退演练。
- 新增两点分钟HTTPS任务持续运行，既有两处443 probe保持。全量API/Worker和Flutter由本任务维护进程；临时ADB VM转发在读取后移除，不留下常驻隧道。
