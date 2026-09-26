# TCP443 与 Release 网络诊断

## 恢复入口

- 用户授权：2026-09-26主服务器443每分钟TCP探针（服务器/大陆各一）、客户端失败计入ChatDiagnostics、401/离线暂存补报、Release上传开启。
- 工作树：C:/Users/Administrator/.codex/worktrees/merge-main-20260926/StarChat；branch codex/netmon-tcp-diagnostics；基线b18f0407。
- 原root仍b9eca8a4，诊断WIP另有快照；本轮从新main隔离实施，不整文件覆盖。
- 设计/计划：2026-09-26-netmon-tcp-diagnostics-design.md / 2026-09-26-netmon-tcp-diagnostics.md。
- 文件所有权：agent mobile=Flutter核心与测试；agent netmon=脚本/infra测试/runbook；root=API接收端、契约、设计计划、任务和索引。
- 当前状态：实现、生产探针/API发布、最终门禁和独立复审完成；源码提交 `31efd61f2f3ec633d2634d1f30cb2636d838c409`。开始：2026-09-26 Asia/Hong_Kong，精确起点未采集；各门禁记录工具耗时，不编造总墙钟。
- 下一步：后续新客户端构建时绑定本源码并验证弱网/401恢复；本轮Git发布结果以私有 `git-delivery.json` 的远端回读为凭据。原已安装2179与正式APK/IPA未在本轮重新构建。

## 验收台账

| ID | 场景 | 状态 | 证据/限制 |
| --- | --- | --- | --- |
| TCP-SERVER | 服务器每分钟TCP443成功率/耗时 | 通过，已安装 | 14:23/14:24两个定时窗口各3次；systemd实际结果0 |
| TCP-CN | 大陆点每分钟TCP443成功率/耗时 | 通过，已安装 | 阿里云SYSTEM任务；两窗口各3次，LastTaskResult=0 |
| CLIENT-FAIL | Timeout/socket/401记录闭集信息 | 最终门禁通过 | instance/generation/session epoch三重隔离；仅公共授权业务请求 |
| SPOOL | 离线/401有界暂存、恢复补报、异步竞态 | 最终门禁通过 | 64KiB/100/24h；本地账号盐HMAC；ACK UUID/原帧组及恢复竞态断言 |
| RELEASE | Release开启ChatDiagnostics | 已确认接线 | 认证scope原本无Release开关；PerformanceMetrics继续profile/diagnostic条件，旧包未改变 |
| CONTRACT | 新stage兼容、旧schema/privacy | 163通过，已上线 | receiver Literal只加network_request，OpenAPI check exit0 |
| VERIFY | 定向/全量/评审真实证据 | 适用独立门禁通过 | verify.ps1缺.env退出1，未把它称作通过；未变输入复用分开记录 |

## 已取得阶段证据（14:17 +08）

- 接收端 RED：新增network_request timeout/network/401三例真实422失败，4隐私拒绝通过；exit1。
- GREEN：完整client_diagnostics模块163 passed、exit0、2.63s；1个已安装Starlette testclient对httpx的既有弃用警告，非此次Literal变化产生。OpenAPI只新增一个enum值，export/check exit0。
- 总verify.ps1真实exit1：Repository/Deployment/TemplateTools通过，隔离树无.env停在RenderOnly；未复制生产秘密或关闭策略。适用独立门禁逐项执行。
- netmon初轮infra197 passed exit0（172现有+25新probe）；后续Windows WSA4例增加需最终29专项复核。某agent默认D:/python/python.exe有已安装regular scripts包导致infra导入失败，原归因“并发新增文件”已纠正；指定py-3.12门禁正常，相关文件本来已跟踪。
- TCP真实候选（未安装阶段）：origin3/3，0.096/0.037/0.039ms；mainland3/3，23.415/13.054/17.969ms。Windows Python3.11采用高分辨率perf_counter_ns避免monotonic_ns粗粒度；不是估算。
- API候选准备：基底2547aafdc52b；候选ea950a2fb0f0；239源码文件仅api/client_diagnostics.py变化，源码SHAe920a4e4…；实际ASGI旧/新契约/隐私门禁通过，oldAPI/candidate/worker各9组refresh门禁通过。0700目录/opt/starchat/releases/netmon-diagnostics-20260926-01保存26,463,746字节备份，隔离network-none PostgreSQL恢复137表/schema0088通过；尚未切换。
- 初次隔离PG恢复失败退出1，未保留敏感stderr，精确原因未知；增加最终PID1与readiness检查后的恢复成功。后续一次有限复现未重现失败，不把初始化竞态推断写成根因。不影响生产，未反复复测。
- 生产代理/日志：json-file20m×10；proxy headers开启、2个forwarded可信条目，无wildcard，gateway被信任。Release仍沿用既有source/account限流。
- API/Worker完整本地门禁另在运行api-worker-full.log，退出未取得，不能声称通过。mobile agent首轮24focused通过，继续补TTL/尾随/restore/generation/严格损坏数据测试，尚未冻结。

## 最终候选与运行态（2026-09-26）

- 两处新probe脚本SHA256 `ec3e2c6b0978b7cad56714c5be85a8258a97e3a7d90a406762053dcf981de531`。14:23和14:24各3/3成功；源站0.044–0.091ms，大陆11.021–18.478ms。只有TCP connect实测，不是TLS/HTTP或全国可达率。每分钟3次，滚动最近60尝试是按数量窗口，不冒称精确20分钟。
- probe部署前后原netmon三SHA/旧timer与27个运行容器ID、镜像、启动时间不变；阿里云142原任务名不变，SYSTEM/private ACL，任务LastTaskResult=0。两处候选、日志和状态权限通过。首次Windows创建因XML不接受ServiceAccount LogonType自动撤回，修正后validate-only/实际定时均通过。正常安装后完整撤回未运行，私有备份与拒绝漂移的回退程序已保存，见[运行手册](../../runbooks/netmon-tcp-probe.md)。
- API-only switch真实exit0：image `sha256:ea950a2fb0f077d4e4617e50899f1359489989c3dc7da156ec173734f7b1244c`，healthy、restart0、HTTPS ready；匿名401，startup ERROR/Traceback各0。schema `0088_profile_grapheme_limits`、其余38容器ID/镜像/启动时间不变。239源码文件仅接收端一文件变化，SHA `e920a4e4ec0e28b64a8819d043c3b9aaee632e53d681b9043ec4576c335120ce`。该枚举不放松身份验证、金融或E2EE规则。
- API备份及兼容回退镜像保留在 `/opt/starchat/releases/netmon-diagnostics-20260926-01`；switch/rollback helper SHA `fe7b0d8231f64b4a27674a2dc1db74771326ef4402221a42290cd64c6aa628cc`，本地/服务器一致；3个mock rollback断言通过，无生产调用。实际正常发布后未执行回退。
- 独立复审新增两项真实问题并作最小红绿修复：完整帧恢复缺失/负数/string计数不能补零；旧202 ACK只能扣同UUID事件与原帧组，不能影响TTL清空后新数据。12个frame RED、3个held ACK RED均按预期exit1；客户端最终定向71 passed exit0，8所属文件Dart分析无issues exit0。
- 修正后独立规格复审PASS，再质量/安全复审PASS；冻结SHA与审核输入一致。含驱逐的held ACK用例也经过TTL释放容量，明确证明的是TTL后同key重新生成UUID的风险，不能称纯驱逐后无空位即重插。修复使用UUID/原组检查，覆盖真实复现路径。
- 前一候选Flutter analyze无issues（10.4s）/Matrix2153 passed、9 skipped/full4464 passed、9 skipped均exit0；上述3处补丁后已串行重跑最终同门禁，不拿旧候选结果冒充最终结果。
- 工件根：`docs/verification/artifacts/2026-09-26/netmon-tcp-diagnostics/`；client专项日志在同日`netmon-client-*.log`及`netmon-frame-restore-red.log`、`netmon-ack-identity-red.log`；probe在`netmon-tcp/`。所有非Git敏感候选/备份仅留私有目录，不提交原始日志或秘密。

## 最终验证结果

| 命令/覆盖 | 结果 | 真实退出码 | 证据与时间 |
| --- | --- | --- | --- |
| flutter analyze --no-pub lib test | No issues found | 0 | flutter-analyze-final.log；8.7s |
| flutter test --no-pub --reporter expanded test/features/matrix | 2153 passed / 9 skipped | 0 | flutter-matrix-final.log；日志最后01:11 |
| flutter test --no-pub --reporter expanded | 4479 passed / 9 skipped | 0 | flutter-full-final.log；日志最后02:49 |
| py -3.12 -m pytest tests/business_api tests/business_worker -q | 2912 passed / 75 skipped / 1 warning | 0 | api-worker-full.log；1880.64s |
| py -3.12 -m pytest tests/infra -q | 201 passed | 0 | infra-final.log；12.78s；含29 probe测试 |
| py -3.12 -m pytest tests/mobile -q | 238 passed / 1 skipped | 0 | mobile-boundary-final.log；11.14s |
| py -3.12 scripts/verify_ui_contract.py | 32 components / 433 screens PASS | 0 | 最终工具回执 |
| py -3.12 -c import app.main | Business API import PASS | 0 | 最终工具回执，未连接生产数据库 |
| py -3.12 scripts/export_openapi.py --check | PASS | 0 | 最终工具回执，仅stage枚举新增一行 |
| docker compose --env-file .env.example config --quiet | PASS | 0 | 最终工具回执，无生产秘密 |
| pwsh -NoProfile -File scripts/verify.ps1 | Repository/Deployment/TemplateTools PASS，缺.env停在RenderOnly | 1 | verify日志；不声明整体通过，不复制生产配置 |

最终源码/测试/契约/探针与pubspec.lock SHA记录在 `final-inputs.json`（实测采集UTC06:36:49）；PowerShell7.6.5、Python3.12.10、Flutter3.44.9/Dart3.12.2、Windows10.0.19045。API/Worker的一个warning是已安装Starlette TestClient对httpx的弃用提示，既有环境问题，未关闭/过滤。所有条件跳过保持原条件，不当作实测通过。

Getui/Matrix Bot、迁移、未变UI等源码与测试输入和此前已通过任务 `d7d09ffb` 相同；限定对应模块/测试/compose/TemplateTools的Git差异为零，按[证据复用规则](../../runbooks/mobile-delivery-workflow.md)复用既有门禁。此次API模型相关完整门禁、Flutter共享完整门禁、infra和mobile边界均重新执行。模板unit在原verify中已实际通过；RenderOnly缺隔离树.env是环境缺口，未据未变模板代码宣称本树渲染成功，也不把重新执行的部分结果覆盖exit1。

阶段计时：总体启动精确时间未知；API/Worker工具31分20秒，最终Flutter按命令日志分别8.7秒/1分11秒/2分49秒，其他工具如上。并行执行，不将这些相加为总墙钟；尾随/ACK复审返工有真实RED/GREEN，尚无单独精确主动工时。

## 交接边界

- 客户端更改只在下一次从本源码构建的APK/IPA生效，本轮没有发布新移动安装包；认证前登录/注册和Matrix SDK直连请求没有被此次公共授权Business API hook全部覆盖。
- SharedPreferences尽力持久化：record只改有界内存和安排1秒尾随任务，磁盘/编码在异步批处理；强杀或存储失败可能丢最后少量事件，响应丢失重试可能重复，不承诺exactly-once。
- 普通登出保留同账号24小时待报元数据，既有salt仍有效时同账号可恢复；切换账号/服务scope丢弃不匹配载荷，Matrix身份清理仍删除salt。scope仅本地核对，不进入wire或header。
- 源站对自身公网IP探测主要验证本地监听/路径；大陆点只代表该ECS路径。客户端DNS/TCP/TLS/TTFB拆分仍unsupported/null，此服务器侧主动TCP探针不能补写为某次客户端请求的TCP阶段。

## 修改文件与源码交付

本轮功能提交 `31efd61f` 仅20个归属文件，不包含本地工件、配置秘密或运行数据库：

| 文件 | 目的 |
| --- | --- |
| apps/mobile_flutter/lib/core/business_api_client.dart | 公共授权入口真实失败记录；只在本地计算账号盐HMAC scope |
| apps/mobile_flutter/lib/core/chat_diagnostics.dart | networkRequest闭集阶段、异步有界暂存/恢复、TTL、ACK和代次隔离 |
| apps/mobile_flutter/lib/core/chat_diagnostics_spool_store.dart | SharedPreferences adapter与严格typed恢复，拒绝腐损完整帧数据 |
| apps/mobile_flutter/lib/core/chat_diagnostics_scope.dart | 会话接线与持久化恢复；复用PerformanceMetrics帧listener |
| apps/mobile_flutter/lib/main.dart | 认证scope传入本地store/拥有者resolver，保留Release上报 |
| apps/mobile_flutter/test/core/business_api_diagnostics_test.dart | Timeout/socket/401及旧会话晚到失败隔离 |
| apps/mobile_flutter/test/core/chat_diagnostics_scope_test.dart | 认证与帧采集开关/生命周期接线 |
| apps/mobile_flutter/test/core/chat_diagnostics_spool_test.dart | 故障暂存、恢复、容量、过期、并发、损坏输入和ACK红绿 |
| scripts/netmon_tcp_probe.py | 真正connect计时、每分钟3尝试、闭集输出与有界state/log |
| tests/infra/test_netmon_tcp_probe.py | POSIX/Windows错误、成功率、计时边界和容量29断言 |
| services/business-api/app/api/client_diagnostics.py | 只扩展接收stage白名单，不改鉴权/限流/响应安全 |
| tests/business_api/test_client_diagnostics.py | 新stage三条正常与四条隐私拒绝红绿，保持旧协议 |
| packages/api-contracts/openapi/liuhetong-v1.yaml | 生成契约的单enum增量 |
| docs/runbooks/netmon-tcp-probe.md | 实际部署、分钟实测、权限、失败及回退边界 |
| docs/runbooks/client-diagnostics.md | Release与补报策略、隐私、兼容和限制 |
| docs/performance/chatflow-performance-diagnostics.md | TCP主动探测与客户端请求阶段的区别 |
| docs/superpowers/specs/2026-09-26-netmon-tcp-diagnostics-design.md | 用户批准的增量方案与责任边界 |
| docs/superpowers/plans/2026-09-26-netmon-tcp-diagnostics.md | 红绿/部署/独立门禁执行台账 |
| docs/workflow/tasks/2026-09-26-netmon-tcp-diagnostics.md | 本记录及真实证据身份 |
| docs/workflow/current-state.md | 跨会话恢复入口 |

Git工作树仅提交本轮归属文件。原root的不同基线/并发WIP没有被reset或整文件覆盖；后续清理只针对本轮codex/netmon-tcp-diagnostics临时分支，保留工件工作树。最终远端main SHA与回读时间写入私有工件，不以文档预写状态代替实际push验证。
