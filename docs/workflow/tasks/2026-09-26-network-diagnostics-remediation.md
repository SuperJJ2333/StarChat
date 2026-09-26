# 网络稳定性与全链路诊断修补：方案任务记录

## 恢复入口

- 目标及授权：用户2026-09-26明确批准“完成修复方案后，推送debug版到模拟器安装”。执行本方案的客户端、探针与 API 最小增量修补，并保留数据覆盖安装雷电 Debug；不切换业务节点池，不发布正式 Android/iOS 安装包。
- 设计：[网络与诊断修补](../../superpowers/specs/2026-09-26-network-diagnostics-remediation-design.md)；计划：[分工作包实施](../../superpowers/plans/2026-09-26-network-diagnostics-remediation.md)。
- 现有事实：[只读审计](../../verification/artifacts/2026-09-26/network-coverage-audit/findings.md)；已完成基础任务：[TCP与暂存](2026-09-26-netmon-tcp-diagnostics.md)。禁止把旧部署历史当实时状态。
- 当前状态：源码/专项和完整 Flutter 门禁通过；NETMON 两点已安装验收，API r4 cf7c4926…已受控发布、健康/零重启且真实request/SQL关联通过。Debug `0.4.13+2180` 固定签名重建18项通过，19:29已保留数据安装雷电，21:40实际VM回读2180/metrics启用。当前捕获真实5007ms TLS失败，继续定位本机Meta TUN共同出口。基线971fb50d193ab1a34610bd7908c2dbf6272db431，分支 `codex/network-diagnostics-remediation`。
- 工作树：`C:/Users/Administrator/.codex/worktrees/merge-main-20260926/StarChat`；root 拥有 core trace/model/metrics、call/search/room_page 和交付文档；独立 agents 拥有诊断队列、Matrix/Outbox 接线、netmon 和 API，文件顺序交接。原main WIP保持。
- 最后更新时间：2026-09-27 00:40香港时间。
- 下一条操作：2182源码/分类器复核通过，最终完整analyze No issues/Matrix2204/full4593均exit0，9条件skip。提交冻结后原生x86_64重建、真实ELF/固定签名验收、保留数据安装并接通VM，请用户新短视频对照。不绕过H264/AAC/20MB/E2EE，具体ABI因果仍待实测。
- 必要外部输入：13节点真实SSH用户/端口及云控制台权限、目标用户地区/运营商；审计已发出问题，尚无答复，分别阻断N01或N04，不阻断其他工作包。

## 验收台账

| ID | 目标 | 当前状态 |
| --- | --- | --- |
| N01/N02 | 次节点入口与雷电路径恢复/定位 | 13 SSH22仍未到认证，待外部入口；19:41雷电HTTPS4/4成功；21:41两端各4/4 TLS失败，TCP已完成，源站ready200；Meta TUN路径机制待定位 |
| N03/N04 | 有界旧探针与完整区域稳定性 | 52专项及infra224通过；Linux/Windows两分钟以上真实调度通过，原443不变；24h/7d和多运营商未取得 |
| C01/C02 | 同根多记录不丢与在途/超期可见 | v3 entry身份、partial索引、checkpoint/expired、100并发联合71通过；2180装机及实际checkpoint→final同根快照通过 |
| C03/C04 | 会话/发送重试与准确网络/帧证据 | B3 220、最终echo58、sync43通过；真实错误、每cycle Watchdog增量、35s正常poll不误判；专项analyze零问题 |
| C05/C06 | DB媒体通话与摘要统计口径 | 实际media-index SQL、单调时钟代表通话样本、setup关联、每次搜索、语义分桶专项通过；未测SDK阶段保持unsupported |
| S01/S02 | 生产request/DB hooks与严格协议 | 最终226通过1PG条件skip；r4 isolated/production真实2worker HTTP/SQL通过，19:13 guard切换exit0、healthy/零重启/38其他容器不变；备份恢复137表/schema0088通过 |
| R01 | 新四位Debug包与正式两端能力对齐 | build2180冻结/合同3通过，完整analyze No issues0/Matrix2180/full4549均0、9条件skip；重建18项/安装/VM回读exit0；已观察一次消息发送；视频重试/补报/Profile仍待验，正式两端未发布 |

## 版本与证据

- 雷电审计时：com.liuhetong.mobile.debug，0.4.13/2179；该旧包不含后续修补；当前已覆盖2180，同一firstInstallTime，APK SHA与VM build实读吻合。
- 源码基线971fb50d，最终编译提交b74cefc8；审计时API ea950a2f，最终7文件增量cf7c4926包括receiver/request/SQL快照接线。后续部署必须重读真实运行镜像。
- 最终汇总及所有实际门禁出口：[交付验收](../../verification/2026-09-26-network-diagnostics-remediation.md)。首次全量analyze发现sealed父类6个override annotation info，修正后 `No issues found` exit0。verify.ps1真实exit1（缺.env）；infra224、mobile238/1skip、UI合同/import/Compose、AST270、Alembic头/离线生成均exit0。未完成的全量/装机门禁不冒称通过。

## 阶段与交接

- 规划阶段开始精确墙钟未保留；07:30:45UTC（15:30:45香港时间）有clock读数，文档核查结束为15:39:57香港时间；不把两读数之差称为完整规划耗时或实施耗时。
- 网络、客户端与API各有独立实现/专项及规格→质量安全复核。额外审查发现准备期间合法echo随后异常会误记failed、真实include_router快照未保留关联，两者已有真实RED/GREEN并在候选验证，不放宽隐私过滤。
- 已修复问题：旧探针无限等待/缺测、未完成trace盲区、视频首次finish抹去重试观察、spool同根去重及ACK身份风险、通用Timeout误标phase、通话末次健康遮盖尖峰、Matrix sync丢真实错误与本轮Watchdog增量。
- 尚未确认：雷电具体网络设备/运营商故障机制、13节点安全组或实例状态、媒体各不可拆阶段真实耗时。
- 回退：Linux/Windows旧探针及私有manifest已备份。API candidate/rollback只差image，旧/新/worker续期门禁及数据库备份恢复通过；只有健康发布失败时才按漂移守卫回退。没有把准备回退命令称为执行了完整回退演练。
- 新增两点分钟HTTPS任务持续运行，既有两处443 probe保持。全量API/Worker和Flutter由本任务维护进程；临时ADB VM转发在读取后移除，不留下常驻隧道。

## 最终装机阶段

源码冻结b74cefc8，固定签名重建19:24–19:28，保留数据安装19:29，21:40:21 VM采集exit0。新版本已真实捕获1001ms checkpoint和5007ms TLS失败final，frames归属不完整则不推断。带profiling参数诊断启动有一次Debug进程native崩溃（处于ARM64桥接环境，原因未证实），普通启动/VM读取成功；不可声称验收窗口零崩溃。21:41宿主机和模拟器各4/4 TLS失败与App失败吻合，源站ready200/healthy，实际Meta TUN路径需继续定位。只读工件失败保留；无APK、正式发布或网络切流重试。

## 实际链路验收增量

21:45 VM已捕获会话729ms/首帧181ms/local timeline640ms，消息发送2102ms/Matrix SDK1707ms，均success；sync processing最大6750ms/55个同期慢帧。21:49只读服务端快照按同根ID对齐59请求，一例客户端1492ms而server16.910ms/SQL4.055ms，剩余等待在服务端处理之外，不能伪称准确网络分段。21:48按本次公开探针端口确证Meta TUN→Selector→Vmess路径，HTTP200但1899.970ms；同路径另窗5秒TLS中断。未调整用户代理/TUN；具体hop未知。普通运行当前保留日志fatal0，历史19:34native crash未抹去。真实视频、weaknet补报、通话、ProfileCPU/内存仍待对应场景。

## 用户实测追加：22时视频失败

用户明确新选取视频失败，一次同气泡重试仍失败。VM地址日志已滚动丢失，未重启以保护队列；改用run-as只取既有诊断偏好键，严格闭集后丢弃scope/queue身份。当前schema3近100条，不含本次视频阶段，服务端2180两批同样没有相关记录；不能按旧文字2102ms记录归因新视频。

已RED/GREEN确定独立诊断缺陷：满载removeLast会删除刚入队的视频错误，legacy新网络错误也被直接拒收。三级O(1)优先索引+实际在途冻结/身份ACK已通过68专项及analyze，仍待新包。另核查到录入容量满时视频根为null永久失联、forward/prepared队列及SDK-only重试无上下文，正在测试优先补上；这不是视频业务失败根因证明。2181已核对当前其他分支/CI引用未占用并冻结构建字段；正式两端未发布。

## 2181规格/质量复核返工

满载保留补丁68通过且三级O(1)索引/frozen身份独立复核通过。发送上下文初轮12专项/266回归通过后，真实适配器复核发现queued retry只返回入队，不能据此记录SDK完成/ACK；同时检查无事件no-op、满容量实际retry计数及页面dispose期间在途SDK的错误取消。正在增加公开可选diagnostics-aware回调，让真正event.sendAgain/room.sendEvent分界发出观察，logical timeline按原路由透传；不改变业务Future、重试、SDK fork或鉴权。上述P1修正前完整门禁未启动，不冒称初轮mock测试完成真实adapter验收。

## 2181最终冻结前计时复核

实际SDK callback的19专项和314回归均exit0，9文件analyze无问题；已修正queued/no-op假ACK、容量满重试计数及销毁后误报timelinePublished。新增复核明确五分钟lease以及容量驱逐会对尚在途SDK提前finish(waitingNetwork)，还发现onRecord抛错可以污染SDK结果。正在通过RED/GREEN做仅诊断的释放和回调隔离，真实SDK返回仍按其结果记录，不改变业务超时；完整2181门禁等待这次源码冻结。

## 2181最终源码验收

满载保留68专项、发送/TTL/observer隔离28专项、对应回归321通过，最后小型完成标记保护也经专项及root完整门禁。23:13结束完整analyze No issues/Matrix2204/full4586均exit0、9条件skip。23:13verify仍exit1（隔离.env缺失），前三项政策/模板PASS。独立复核并逐文件SHA匹配。此前等待冻结和正在修补文字是阶段历史，当前下一步为提交/重建/装机。2181尚未安装，真实视频业务根因未确认。

## 2181实际装机反馈与2182原生环境对照

2181已安装23:26:52，设备SHA/firstInstallTime一致，metrics VM回读成功；用户新视频实际root转码双native_failure（700ms总/269ms至失败），未进入网络阶段。原始日志不保存，同UIDcodec probe仅公共创建能力成功并清理。2182已核对本地/remote refs和任务构建占用，未发现冲突并冻结字段；原生x64 helper独立生成，正式ARM门禁不改。源码classifier修补TDD进行中，尚未执行2182全门禁/构建/安装。与同期旧消息成功1665ms分开，旧视频重试缺可关联记录不作归因。

## 2182源码冻结前最终验收

分类器21专项/独立规格及安全复核PASS；真实native失败优先，未知/取消/成功回退/后续进展不误归因。完整测试初次held-forward的1秒等待断言失败，focused旧版1仍通过；只将测试同步改为真实drain Future+10秒期限+必要pump，原加密/一次发送断言保留，4专项通过。最终00:38:21全量analyze/Matrix2204/full4593均exit0、9条件skip。源码待本次提交后原生x64构建；2182尚未安装，不声称视频恢复。
