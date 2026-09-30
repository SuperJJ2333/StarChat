# 用户上传网络与性能日志检查

## 恢复入口

- 用户授权：检查上传的网络监控和性能检测日志是否仍有异常。范围为生产只读调查和脱敏统计，无客户端构建、业务写入或服务发布。
- 关联流程：[生产工作流](../../runbooks/admin-production-workflow.md)、[请求诊断手册](../../runbooks/network-request-diagnostics.md)。
- 当前状态：检查完成；新版Android2188仍有等待响应头超时、Matrix同步失败、媒体加载失败及局部帧超预算。未实施修复或发布。
- 所有权：Root只拥有本任务记录、汇总报告、network-*工件；性能agent只拥有本轮performance-*；独立审查只拥有network-evidence-review.json。不修改应用源码或已关闭任务。
- 主目录：D:/pythonProject/outsource/StarChat，只读调查无需新工作树。证据目录为docs/verification/artifacts/2026-09-28/user-diagnostics-review/。
- 最后更新时间：2026-09-28 02:57+08，实际工具UTC见工件。
- 下一步：检查已完成。后续修复优先沿同请求ID定位客户端/入口链路及媒体慢请求，再分析同步与媒体failed的阶段；不能从这些有界样本直接选择主区或判定数据库/S3根因。

## 验收台账

| ID | 检查内容 | 当前证据 | 状态/缺口 |
| --- | --- | --- | --- |
| D01 | 当次服务身份与日志覆盖 | API5e43/e304，2026-09-27T13:44:25UTC启动 | 已确认，仅当前容器约5小时，24h请求窗口不代表24h完整留存 |
| D02 | 网络摘要与按UUID关联 | network-requests-compatible-live/report、network-request-aggregate | 97独立失败请求；新2188占68，全部8秒awaiting_headers超时 |
| D03 | 性能帧与操作统计 | performance-aggregate-result/stage | 完成：409合法批次，Android2188与iOS2173分开统计；biased sample和无frame去重ID限制保留 |
| D04 | 当前/历史区别与复核 | network-evidence-review | PASS：独立复算97/68及关联子集一致；未知原因保留，不将ASGI完成当手机收到 |

## 阶段计时及证据

调查从2026-09-27 18:44–18:45UTC开始，精确首条命令开始时间未保留，主动耗时未知。当前源/工具版本和采集UTC写入最终证据清单。原始日志不离开服务器，不导出用户标识、IP、正文、环境或原始错误文本；导出的请求UUID仅为既有闭合协议的随机请求标识，最终聚合不含UUID。

初始既有请求collector E55A4356遗漏外层version/platform，得到14524 server-only记录，不能判定无客户端失败。本轮仅在工件目录复制并修正兼容读取，不修改scripts或生产。首次复制工具54fbe的远程伪file路径层数不足导致exit1；无原始输出导出，失败版保留。路径修正后的fa1e5f84读取70618行、14692合法记录，无截断/导出溢出/非法子记录；rejected_lines=55621包含非目标访问日志等采集分类，不能当业务故障。

97独立客户端失败=旧2187的29+新2188的68；48有服务端complete、49无记录。server_application_over_client_budget=1属于48的子集，不相加成98。无同请求ID冲突或重复客户端记录。新版68按类别为contacts46/media8/settings8/support4/other2，WiFi53/VPN15；41matched complete和27missing。WiFi匹配27的server耗时最大104ms，VPN匹配14最大17670ms。所有物理链路和无记录请求原因尚未确立。

## 交接与边界

- 旧2187的3次HTTP5xx只在API切换21:44:25–30+08附近，不能冒称新版持续5xx。
- 无iOS新请求失败记录不代表iOS无故障，覆盖须按实际性能上传再确认。
- 未发布或重启，不处理历史Outbox；本任务不改变前轮Outbox/网关已验收结果。
- 后续修复需根据本报告独立定位，不通过扩大超时或屏蔽告警来宣称解决。

## 最终检查点

性能实际只读工具于2026-09-28 02:52:25.564→02:52:30.038+08 exit0（4.475秒），扫描71000行/409合法批次，无schema拒绝或扫描限额截断。当前Android2188有94批、1075个去重final操作：API897中206failed/158rejected；Matrix92中43failed；media28中14failed/13cancelled。首帧及本地timeline样本较快，但远端同步等待差值可达14.246秒。32个frame batch中位慢帧占比1.47%、最差23.31%；iOS2173的63个frame batch中位0.20%，缺新network/request/operation明细。异常优先采样，不推断总体失败率或p95。

网络摘要1090个不可变sample去重、13重复/0冲突；2188 WiFi4214尝试中123timeout/2networkerror，VPN3387中14timeout，none31全部networkerror，不能把摘要与详细请求/trace相加。性能5operation/5event ID冲突保守排除，不认定生产非法。网络独立复核5811eb60通过，留存与因果缺口保持。详见[汇总报告](../../verification/2026-09-28-user-diagnostics-review.md)。当前未创建隧道、未重启或部署，无运行中的Root工具。
