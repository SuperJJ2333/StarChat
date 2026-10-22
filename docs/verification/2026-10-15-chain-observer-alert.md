# 2026-10-15 链上观察P1告警调查

## 结论

2026-10-15 06:02–06:04（北京时间）只读调查。告警事件3d2529f2-9d9c-4227-ab40-ae7cad4500f6、事故3f86ae92-038c-4816-b40d-b92a887bbb6e已与观察run100510及保留的observation99877对齐。直接失败原因是SOLID_HEAD_REGRESSED，不是已证实的进程崩溃或钱包差额。本次没有修改生产代码/配置、重启服务、暂停/解除钱包或写入资金记录。

## 时间线（北京时间）

- 05:35:34.535：observation99877成功，stable_balance=1、SOURCE_MATCHED。邮件中的该ID是失败时最后一份成功观察，不能说99877自身采样失败。
- 05:36:08.278：run100510开始，原checkpoint保留。
- 05:36:11.476：3.197秒后reader.py:269抛出TRON solid head regressed。此处是同一次snapshot再次尝试时，新读到的区块高度或时间戳低于前一轮minimum_head；失败事务回滚，未推进checkpoint。
- 05:36:21.210：事故重新打开并产生事件；邮件12秒是截至告警时从失败采样起点计算的持续时间，不是故障最终总时长。
- 05:36:22.974：SMTP receipt记录；对应Outbox PUBLISHED、attempt_count=1。
- 05:36:41.478：下一轮run100511开始，最终OK；后续观察99878/99879/99880连续SOURCE_MATCHED。
- 05:37:53.097：condition_active=false，cleared_at已设置；status仍OPEN、resolved_at为空，表示未人工结案，不代表异常仍活动。
- 检查时最近6轮观察全部stable/SOURCE_MATCHED、run全部OK。

## 频率

| 范围 | 实际结果 |
|---|---|
| 近24小时观察运行 | 2610 OK、2 ERROR（SNAPSHOT_FAILED），失败率约0.077% |
| 近7天观察运行 | 18343 OK、5 ERROR；3 SNAPSHOT_FAILED、2 SOURCE_NETWORK_ERROR |
| 近24小时成功观察 | 2526 stable/SOURCE_MATCHED；45 unstable/UNVERIFIED、39 stable/UNVERIFIED，不把运行OK等同资金证据健康 |
| 近24小时同类邮件 | 2封 |
| 近7天全部钱包SMTP告警receipt | 3封，均MANUAL_SOURCE_UNHEALTHY，分别10月13日18:23、14日18:38、15日05:36 |

24小时内两次scan_failed均记录SOLID_HEAD_REGRESSED（另一轮run99322，10月14日18:38:00）。另有一次READ_TIMEOUT请求日志但没有对应最终运行失败，不能把单次请求重试当失败采样。服务端receipt统计不证明收件方邮箱无重复投递。

## 根因分层

1. **已确认的数据源读取不一致**：生产reader在同次快照重试时遇到已确认区块头倒退并拒绝该数据。上游节点进度不一致/负载均衡返回较旧节点是可能解释；历史日志未记录两次具体头部值及后端节点身份，不能证明真实链重组或具体供应商节点故障。
2. **已确认的错误原因丢失**：observer.py:193–194仅对ObservationError和TronTemporaryReadError保存具体原因；TronReadError落为SNAPSHOT_FAILED。diagnostics保留SOLID_HEAD_REGRESSED，但SQLite runs与邮件路径未保留。funding_source.py:199–200再映射SOURCE_RUN_ERROR，所以邮件显示“底层起因尚未确认”。
3. **已确认的通知分类差异**：生产TRANSIENT包含网络/HTTP错误、证据短暂过期、不稳定余额及待对账；不包含SOURCE_RUN_ERROR。incidents.py:222仅对TRANSIENT且小于600秒缓冲。本次为非瞬时分类，因此12秒即可P1；连续3个不同健康observation后清除条件，下一次失败重新打开，形成反复通知。
4. **未见崩溃证据**：watch/API/worker当前healthy，RestartCount=0、OOMKilled=false。此证据不等于所有业务流程健康。香港另有历史recovery演练worker unhealthy，与本次运行链路不同，未据此归因本事故。

## 修复方案与验收

- P1：以安全枚举端到端保存SOLID_HEAD_REGRESSED/CONFLICT等原因，邮件显示明确根因及run_id/观察ID；不输出地址、密钥、交易正文。验证异常从reader→observer→SQLite→funding_source→incident→邮件不再退化UNKNOWN。
- P1：对可识别的头部落后执行有限次数/总截止时间内完整快照重试，保留已见最高头部，严禁降低minimum_head、拼接旧余额/新事件或推进失败checkpoint。模拟倒退→恢复、持续倒退、相同高度冲突、deadline耗尽，证明未验证数据不会进入资金授权。
- P2：在原因分类准确后，仅针对经定义的短暂数据源落后设计连续失败或持续时间通知阈值；所有失败仍记录，证据校验继续拒绝。不把SOURCE_RUN_ERROR整体加入忽略/缓冲名单，不更改差额、冲突、未知出款的立即告警规则。
- P2：增加安全的前后区块高度/时间、请求耗时与供应商标识诊断，再评估稳定节点/容灾源。不同数据源不得未经一致性验证合并资金证据。

产品修复尚未实施；本次交付为已定位根因的只读排查。涉及资金证据及保护策略的实际变更需按项目ADR/领域与质量安全评审执行，不以重启、延长所有阈值或自动结案掩盖问题。

## 证据与限制

[运行与诊断](artifacts/2026-10-15/chain-observer-alert/runtime.json)、[SQLite只读聚合](artifacts/2026-10-15/chain-observer-alert/sqlite.json)、[事故与邮件读回](artifacts/2026-10-15/chain-observer-alert/business.json)、[实际生产通知策略](artifacts/2026-10-15/chain-observer-alert/policy.json)、[7天邮件频率](artifacts/2026-10-15/chain-observer-alert/frequency.json)。生产PostgreSQL事务显式READ ONLY并设置8秒查询超时；SQLite使用mode=ro/query_only。一次统计SQL因保留别名day失败，改为bucket_day后通过；失败只读事务回滚，不作为产品异常。未下载数据库、地址、密钥或消息正文。
