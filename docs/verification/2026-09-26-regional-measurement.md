# 双区域选址观测增量验证（2026-09-26/27）

源码、兼容接收候选、探针/报告和永久安全收集器完成；规格及质量/安全复审PASS。完整仓库verify已exit0，最终Flutter4034通过、全analyze0 issue、mobile108/1条件跳过及工具73通过。**本轮未发布新接收端或客户端，没有有效networks现场样本，也没有足够证据决定香港或新加坡主区。**

依据：[设计](../superpowers/specs/2026-09-26-regional-measurement-design.md)、[计划](../superpowers/plans/2026-09-26-regional-measurement.md)、[任务及计时](../workflow/tasks/2026-09-26-regional-measurement.md)。用户批准实施，随后说明没有独立测点，授权真实用户日志检测并要求增量放下一次更新；不包含购买、生产切流、主站/主库迁移或S3搬迁。

## 来源与实现

工作树`C:/Users/Administrator/.codex/worktrees/regional-measurement/StarChat`，分支`codex/regional-measurement-20260926`，基线`b9eca8a419614112b085439445b7fd031027a740`，继承80个主目录既有改动作为[input快照](artifacts/2026-09-26/regional-measurement/input-snapshot.json)，保留账号/OTP等输入。仅本任务所有权文件允许回填，不提交继承改动。

- 客户端：已认证scope中的物理HTTP尝试按完整2xx/3xx/4xx/5xx、网络错误、超时、取消计数；完整body消费后才计完成。成功2xx九个非累计桶，固定连接方式枚举；不采集URL、IP、地区、运营商、用户标识、正文或凭据。原sample_id、版本/platform和UTC窗保持不可变，重试/上传期间新样本/账号代次隔离；schema2补报保存来源，缺来源的旧schema1显式丢弃。队列/补报/上传缺失及未消费流不能当精确全用户可用率。源码/工具/锁及阶段回执见[client-receipt.json](artifacts/2026-09-26/regional-measurement/client-receipt.json)。
- 接收端：可选networks≤8、strict类型/未知字段拒绝、UUIDv4批内唯一、有序UTC时间窗、结果和=attempts、九桶和=http_2xx；networks-only可202，accepted仍表示events数量。原认证、限流、16KB流式输入和events/frames语义不变，无数据库/金融写入。OpenAPI导出相对继承输入仅改变诊断路径，账号/OTP及其他路径保持。
- 工具：有限HTTPS探针保留证书校验、禁重定向/隐式代理/自动重试，记录失败分母和DNS/TCP/TLS/TTFB/total；指定IP保留同域名SNI并明确绕过DNS。报告按路径信任、DNS绕过及代理条件分组，sample_id去重、内容冲突拒绝；成功桶仅给近似分位数上界，溢出桶无有限上界，始终返回evidence_insufficient。
- 安全收集器：仅经既有`starchat-server.ps1 -Action Command`/strict jumper，固定读取业务API容器日志。远端内存中的审查程序先验证并剥离旧events/frames，只有闭合networks可导出；原始日志、异常文本、账号、IP和凭据不出站。默认72h/20000行、硬上限72h/100000行，净化输出另限16MiB/20000摘要；输出JSONL和独立meta真实resolve限制在artifacts，缺输出不伪装零失败率。调用见[操作手册](../runbooks/network-probes.md)。

## 红绿、审查与门禁

| 范围/命令 | 真实结果 | 证据 |
| --- | --- | --- |
| 客户端`flutter test ...network_diagnostics_test.dart --reporter expanded` | 初始4失败/1通过，exit1；重试/超时/历史、clock、代次/丢失、UTC/旧spool、帧恢复均有追加红证据 | [红](artifacts/2026-09-26/regional-measurement/client-red.log)、[receipt](artifacts/2026-09-26/regional-measurement/client-receipt.json) |
| 客户端业务相邻专项、最终受影响专项 | 88通过exit0；最终诊断/scope/frames等42通过exit0；analyze0 issue/exit0 | [业务相邻](artifacts/2026-09-26/regional-measurement/client-green.log)、[最终专项](artifacts/2026-09-26/regional-measurement/client-green-review.log)、[analyze](artifacts/2026-09-26/regional-measurement/client-analyze.log) |
| 服务端`py -3.12 -m pytest tests/business_api/test_network_diagnostics.py -q` | 初始11失败/58通过，exit1；合法networks因缺实现422，属于预期红 | [红](artifacts/2026-09-26/regional-measurement/server-red.log) |
| 服务端新旧诊断、OpenAPI及钱包客户端契约相邻 | 115通过exit0；扩展相邻139通过exit0；OpenAPI --check PASS/exit0 | [绿](artifacts/2026-09-26/regional-measurement/server-green.log)、[相邻](artifacts/2026-09-26/regional-measurement/server-contract-green.log)、[OpenAPI](artifacts/2026-09-26/regional-measurement/server-openapi-check.log) |
| `py -3.12 -m pytest tests/infra/test_network_probe.py tests/infra/test_network_report.py -q` | 缺实现18失败exit1→19通过exit0；DNS绕过/正常路径混组缺口追加红后修正 | [红](artifacts/2026-09-26/regional-measurement/tools-red.log)、[分组红](artifacts/2026-09-26/regional-measurement/report-path-red.log)、[绿](artifacts/2026-09-26/regional-measurement/tools-green.log) |
| 安全收集器专项+以上工具专项 | 收集器初始40失败exit1；meta路径、资源限制、扫描不预读均有红证据；最终54+19=73通过exit0，独立复验54通过exit0 | [初始红](artifacts/2026-09-26/regional-measurement/collector-red.log)、[meta红](artifacts/2026-09-26/regional-measurement/collector-metadata-red.log)、[资源红](artifacts/2026-09-26/regional-measurement/collector-resource-red.log)、[扫描红](artifacts/2026-09-26/regional-measurement/collector-scan-bound-red.log)、[最终绿](artifacts/2026-09-26/regional-measurement/collector-final-green.log) |
| 根代理最终工具与mobile增量 | 工具73通过exit0/reporter1.29秒；mobile108通过/1条件跳过exit0/reporter4.97秒；仓库policy再次PASS | [工具](artifacts/2026-09-26/regional-measurement/tools-final.log)、[工具结果](artifacts/2026-09-26/regional-measurement/tools-final-result.json)、[mobile](artifacts/2026-09-26/regional-measurement/mobile-final.log)、[mobile结果](artifacts/2026-09-26/regional-measurement/mobile-final-result.json) |
| 规格后质量/安全审查 | 修正后PASS；服务端独立115专项通过；工具混组与收集器资源门禁P2均已关闭；本地生成远端程序模拟、编译、字段/枚举一致及diff检查通过 | 审查回执在本任务会话；源码/日志身份如下，不冒称生产验收 |
| `pwsh.exe -NoProfile -File scripts/verify.ps1` | exit0；infra165、Getui28、Matrix Bot9；API/worker2862通过/87条件跳过；mobile边界108通过/1跳过；策略、UI契约、导入/AST、迁移、OpenAPI、Compose通过 | [日志](artifacts/2026-09-26/regional-measurement/verify.log)、[结果](artifacts/2026-09-26/regional-measurement/verify-result.json) |
| 最终Flutter全量与全analyze | 4034通过exit0；全analyze No issues found/exit0/reporter19.5秒；这两项覆盖最终冻结客户端，不将verify中的Python边界测试当Flutter全量 | [全量](artifacts/2026-09-26/regional-measurement/flutter-full-test.log)、[退出回执](artifacts/2026-09-26/regional-measurement/flutter-full-test-result.json)、[全analyze](artifacts/2026-09-26/regional-measurement/flutter-full-analyze.log)、[analyze结果](artifacts/2026-09-26/regional-measurement/flutter-full-analyze-result.json) |

`client-green-final-delta.log`实际exit1、0通过/1加载失败，原因是测试_IOResponse构造器同时使用super.stream和super(200)，并非功能测试通过。已改显式stream+super(stream,200)，随后21专项可加载，UTC/schema1各有预期红，最终42通过包含四个delta；4034全量也通过。原失败日志保留，[更新后receipt](artifacts/2026-09-26/regional-measurement/client-receipt.json) SHA256为`6f65a93566b010bdd5c14739201f5d5d10fce92aa10ead03460a94dcad26f905`，六个候选源码hash未变。服务端Starlette/httpx等既有依赖弃用提醒未通过升级或忽略来隐藏，完整verify保留真实警告/条件跳过；没有新增测试skip制造通过。

完整verify于23:42:22结束，早于最终客户端冻结。对未变backend/infra输入复用该门禁，客户端后续修正由最终受影响42、Flutter4034、全analyze和mobile增量覆盖；后加入安全收集器另由54专项及最终工具73补齐，不把早期verify声明为全部后续输入已重新完整执行。

证据环境：客户端Flutter3.44.9/Dart3.12.2、PowerShell7.6.5、Windows10.0.19045；Python专项3.12.10。pubspec.lock SHA256为`484a85f5521a3fcce8c47bf8300c705a9c7f04c28ed82cbfad85370d9db05051`，与主目录一致。完整verify的本地隔离.env来自版本化.env.example，没有导入生产秘密。

| 候选文件 | SHA256 |
| --- | --- |
| services/business-api/app/api/client_diagnostics.py | C2B26867E2C58C90EB9F1F2A3869AE66DF1CAD6A4C9FE86EF960CFAF7CE42013 |
| tests/business_api/test_network_diagnostics.py | D512A11F38F43ADE232006A7A94552EAB399B4CFC3FDC64105F2E15CCEBFEAF1 |
| packages/api-contracts/openapi/liuhetong-v1.yaml | 378406420FD9B793F6C5186D899660707C5BD14A8A069DA39A67AFE38F9B7960 |
| scripts/collect_network_diagnostics.py | 8EB714D4FBF1823B7DDC74E8FCA7EF84CF30A2D17B7D554C32D297CFC3637385 |
| tests/infra/test_network_collection.py | 1EFF018603E3C3139409F692DB0EFA6510732990AC8577746FE9327DEE38D551 |

其他客户端候选hash以client-receipt为准；这些是本地输入身份，不能称为线上镜像或安装包hash。

[最终来源复核](artifacts/2026-09-26/regional-measurement/final-source-check.json)确认OpenAPI仅诊断路径变化、schemas零变化，六个客户端源码hash与receipt一致，依赖锁未变。

## 只读现场及测量限制

HK快照于2026-09-26 23:08:05.446+08：8逻辑CPU、约7.7GiB内存；业务/Matrix/TURN等既有容器可见，业务API日志轮转实际20m×10。早期72h/tail5000聚合看见31旧诊断批、0 networks，覆盖已截断；旧event.max/count/帧分母不是HTTP请求分母或P95/P99。[HK净化快照](artifacts/2026-09-26/regional-measurement/hk-readonly.json)

SG快照于23:08:06.058+08：4逻辑CPU、约7.5GiB内存、根盘总约7.9GiB/空余约6.3GiB；docker inventory exit1、空容器/诊断列表，**只表明本次未观测到同栈服务，不能仅凭exit1断言机器绝无Docker或给它业务性能评分**。[SG只读快照](artifacts/2026-09-26/regional-measurement/sg-readonly.json)

工具受控验证为mock runner的CLI契约用例，未执行实际loopback TLS端到端验证。工作站固定IP/SNI公开路径短测两目标各3次，无成功样本；报告保留绕DNS/透明路径未验证标记，不把它当大陆三网可用率。一次SSH隧道尝试被自动批准审查以policy拒绝，未创建隧道；改用既有SSH只读执行HK服务器自身urllib健康请求，3/3成功，总耗时约15–17ms，仅服务器自测路径，不能代表真实用户。SG没有同栈应用对照，当前HTTP探针不证明消息、TURN、容量或故障恢复。[初始分组报告](artifacts/2026-09-26/regional-measurement/initial-probe-report.json)

永久安全收集器最新实测00:16:21–00:16:23+08，exit0。默认72h/tail20000，实际扫描20000行：0有效networks批/摘要、92旧诊断行、19908拒绝行；rejected_lines包含非目标日志/不可导出记录，不是请求失败次数，拒绝原因不导出原日志。`truncated=true`表示到达tail而历史可能截断，`export_limit_reached=false`，日志留存未验证。JSONL空文件是有效采集结果，**不等于无请求、无失败或服务器不可用**。[采集结果](artifacts/2026-09-26/regional-measurement/collection-result.json)、[覆盖meta](artifacts/2026-09-26/regional-measurement/user-network-collection.meta.json)、[净化JSONL](artifacts/2026-09-26/regional-measurement/user-network-collection.jsonl)、[用户报告](artifacts/2026-09-26/regional-measurement/user-network-report.json)

## 时长及下一步

首次精确准备记录22:52:53.569+08；完整verify23:11:57.906→23:42:22.242，工具墙钟30分24.337秒。客户端最终专项analyze开始23:48:24.527、结束23:48:27.288，受影响专项结束23:48:30.775。安全收集00:16:21.330→00:16:23.083；Flutter全量00:16:21.321→00:22:47.106，墙钟6分25.785秒。工具00:20:47.877→00:20:50.772；mobile00:23:15.752→00:23:21.714；全analyze00:23:15.637→00:23:38.431。工具reporter时长与总命令墙钟分别记录；其余起止、主动执行、外部等待和部分返工时间未知，不根据mtime推算，也不累加并行任务时长。

回填仅包含根代理manifest中的24项归属文件；预检确认全部80个继承输入hash未变，另两个原干净tracked文件与HEAD复核。回填身份与输入保护结果见[回填收据](artifacts/2026-09-26/regional-measurement/integration-receipt.json)。不复制脏树、生产.env或其他任务文件，不提交本轮改动。后续按已授权的下一次更新顺序先兼容接收端后客户端，并分别记录实际部署/包版本与真机反馈。确认生产有新networks后才开始7–14日窗口，覆盖晚高峰和周末；采集频率先按日志增长、轮转留存和tail上限评估，默认20k行可能只覆盖短窗，不保证全天记录。独立快照保留meta并去重。

尚缺地区/运营商测点、两地同栈对照、消息端到端与通话中央采样、带载和恢复演练；本轮报告仍为`evidence_insufficient`。边缘/S3是修正后的草案，没有创建边缘服务、迁主库、修改DNS/TURN列表或搬媒体，不把源码完成写成选址或发布完成。
