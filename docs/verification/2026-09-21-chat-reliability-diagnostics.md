# 聊天可靠性、历史性能与自动诊断验证

## 范围与事实

用户授权修复发送红标、历史滚动跳跃/卡顿、关键字与日期卡死，并要求无操作负担的服务器异常日志。独立分支 `codex/chat-reliability-diagnostics-20260921` 基于 `3d968997`；不覆盖主树其他任务。原始异地弱网事故缺少两端失败日志，不能把本次修复等同唯一现场根因已证实。

| 验收 | 实现 | 核验 |
| --- | --- | --- |
| 发送 | SDK保留Matrix/HTTP原异常；settled请求finally释放；429/5xx按同txid最多3次2/5/15秒退避，遵守Retry-After；设备全局网络状态不被服务器错误污染；后台发件箱同样处理 | send-date红绿、closed-room诊断及最终Flutter门禁 |
| 历史 | 来源索引查找不逐条重建全时间线；惰性稳定center切窗，首帧保持锚点，保留新消息跟随和原气泡实例 | snapshot次数2008→2；逐帧Y误差0、5000px行、双向/手势；合成fixture不代表真机帧率 |
| 搜索 | 每批3页/600条/2秒；每64条让出事件循环；索引beforeEventId续查；迟到最后页不丢；无结果未取尽保留继续；日历取消旧搜索 | 1000条跨7页总访问1000；50,000来源取600只投影600；取消、迟到、空态及页面测试 |
| 日期 | timeout/403保留unknown/error，不把月历误标空；单源与逻辑会话总预算；取消即时返回、迟到结果隔离 | 日期/月/多来源红绿测试 |
| 诊断 | 闭合stage/error/status/耗时/次数/随机UUID；无正文/搜索词/标识/任意异常；100内存、20/批、60秒、5秒真实断开、15分钟退避上限；会话切换清理 | 队列/风暴/代次/真实socket测试；Dart→FastAPI真实loopback202与429不登出 |
| 接收器 | 认证、流式16KiB、strict白名单、账户/IP限流、结构化stdout；无业务数据库写入 | 后端/OpenAPI26项；生产候选8项隔离smoke；生产切换另记 |

## 输入与门禁

所有日志、命令、真实退出码和文件hash位于 `artifacts/2026-09-21/chat-reliability-diagnostics/`。Flutter3.44.9/Dart3.12.2、Windows；依赖lock只镜像host漂移已恢复，未变依赖版本。

首轮全Flutter3723通过/7失败，exit1：6项为长Windows路径造成PathNotFound，短路径同源35项全通过；1项旧ListView finder经新AnchoredTimelineList适配，保留实际拖动断言。不得把首轮写成全绿。最终短路径全量3740通过、0失败，exit0；全analyze无问题、exit0。1146输入before/after只有发送预算说明注释变化，执行代码不变。22:30:00至22:35:48（测试输出5分35秒）。

`verify.ps1`从本工作树.env.example复制隔离render配置启动，未读生产秘密。完整结果exit0：API/Worker2231通过、58条件跳过（1397.32秒）；infra143/getui28/bot9/mobile84；UI契约32组件375页面、迁移、OpenAPI与Compose通过。既有Starlette/Pydantic弃用告警已留证，原生日志/签名/设备反馈不能以此替代。

## 生产与交付边界

诊断候选构建在现行生产镜像之上，仅新增接收器及main注册两文件，运行环境、3挂载和20m×10轮转保留；仅新增精确网关trusted-forwarder。完整可审查manifest、隔离smoke、rollback与漂移检查见 `diagnostics/candidate/REVIEW.md`。22:33接收端已切换并在22:34独立读回：health200、unauth401、image/source/config/mount/rotation正确，其他服务未变；未伪造生产会话或写入测试诊断。

本任务未产生新Android/iOS安装包。旧TestFlight2145在另一工作树且等待用户出口合规；不能冒称包含本次修复。新包须先整合该任务的已批准重启/权限修复，使用新build并按既有内部测试渠道交付。

诊断不弹窗、不要求手动导出，不阻塞聊天关键请求；真实性能收益及Android/iOS弱网/长历史场景仍待新包真机复验。收集器是内存有界队列，进程被杀/系统级卡死前未上传的批次可能丢失；不宣称这是完整native crash/ANR采集。底层不可取消SDK请求不被伪装为已停止，仍保持加密与同txid所有权。
