# 请求失败分类和时间线关联实施计划

> For agentic workers: 使用subagent-driven-development，按下列归属执行；先规格复核再质量安全复核。

**Goal:** 安全区分失败类型与可观测阶段，用每次请求随机ID关联服务端时间线，明确历史证据缺口。

**Architecture:** 保留原传输/超时/重试，闭合可选network_requests扩展既有认证接收端；有界客户端spool和服务端日志队列。生产源码从新live精确冻结，候选仅叠加此诊断增量。

**Tech Stack:** Flutter/Dart http、FastAPI/ASGI、Pydantic、现有SSH、Python离线闭合报告。

## Task 1：客户端请求记录（client owner）

Files：lib/core/network_diagnostics.dart、新network_request_diagnostics.dart、business_api_client.dart仅constructor诊断传输配置；test/core/network_request_diagnostics_test.dart及相邻network/business tests。不编辑chat_diagnostics.dart。

- [x] red：generic exception须细分，headers/body阶段与8秒预算/迟到结果一次计数，401不同实际send的新UUID，私有URL/内容不得进入。
- [x] 按设计建立immutable闭合NetworkRequestDiagnosticSnapshot.tryParse/toJson/requestId；NetworkDiagnostics新增pendingRequests(limit=8)、restoreRequest、acknowledgeRequests、forRequestPersistence、hasPendingRequests、droppedRequests。当前账号generation严格隔离，最多64排队，snapshot immutable。
- [x] 只对configured baseUri origin及活动诊断会话生成请求头；排除client-diagnostics本身。原聚合结果和原发送/取消/timeout语义保留，不引入DNS探测。
- [x] 有意义专项green、analyze与真实退出/输入SHA，交接公开接口供spool owner使用。

## Task 2：spool/上传兼容（root，接口完成后）

Files：lib/core/chat_diagnostics.dart、test/core/network_request_spool_test.dart及相邻spool/compat tests。

- [x] red：新失败记录按8/20/16KiB预算，202确认、422只剥新扩展，原network/event/frame/operation仍上传，重试/恢复UUID不变，换号迟到不入新scope。
- [x] 扩展当前regional/retained spool闭合路径；64等待有界，记录drop；旧格式不变，不新增1秒小窗口summary。
- [x] 相关focused green；客户端与server JSON golden契约匹配。

## Task 3：服务端与时间线（server owner）

Files：app/api/client_diagnostics.py、app/core/tracing.py、新app/core/network_request_timeline.py，tests/business_api/test_network_request_diagnostics.py/test_network_request_timeline.py，OpenAPI。agent先冻结live source/public身份，禁止导出runtime env/原始日志。

- [x] 先测试extra/enum/budget/id/date/duplicate/权限/旧格式兼容失败及ASGI真实send生命周期。
- [x] 最小可选接收扩展及有界非阻塞固定日志，准确headers/body-prepared/send-finished/termination；原DB/audit/operation行为不改。
- [x] queue满/global cap丢弃可见，无自由文本/敏感上下文；focused green并给出installed Linux门禁路径。
- [x] 基于freshlive准备仅此增量候选与兼容回退，保留S3/PHONE/receiver，不包含startup route；候选与实际生产事实分开。

## Task 4：闭合collector/report及历史调查（root）

Files：scripts/collect_network_request_diagnostics.py、scripts/network_request_report.py、tests/infra/test_network_request_collection.py；docs/runbooks/client-diagnostics.md/network-probes.md和本任务验证。

- [x] red：敏感/未知/非法记录剥除，duplicate/晚到/时钟偏差/缺少单边/覆盖截断正确。
- [x] 单请求ID精确join，保留server时间/monotonic边界，报告unknown而不猜测断网；原始日志不出站。
- [x] 只读核对旧2184错误时间段的server保留/部署/粗统计，能确认时引用，缺失不可逆时记录。

## Task 5：门禁、交接

- [x] ownership/输入/环境preflight、focused→spec→quality/security；fullFlutter/analyze与scripts/verify一次适用完整门禁，真实失败闭环。
- [x] 冻结来源；按现有Debug授权必要时递增版本重建/签名/保留数据安装，未授权正式分发。Windows不能替代iOS原生构建。
- [x] 当前生产源精确candidate installed Linux/API验证及回退兼容；服务发布授权针对新候选另行交付，不复用PHONE-only批准。
- [x] 漂移保护回填D，仅本任务文件/安全证据；current-state只更新本条，保留SG/S3。记录起止、真实状态与下一条操作。

执行备注：实现/专项/适用门禁/候选/Debug安装已完成；生产API已获具体候选批准并发布验收。原完整脚本非零及各影响闭环见任务记录，勾选不代表原整套exit0。
