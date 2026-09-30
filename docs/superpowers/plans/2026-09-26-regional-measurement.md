# 双区域选址测量实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans to implement this plan task-by-task. 本次用户已要求执行，不重复请求执行方式。

**Goal:** 为下一次更新提供真实用户请求分母和耗时分布，交付可验证探针及报告，并修正选址前提。

**Architecture:** Flutter固定摘要经既有鉴权诊断端点上传，Python在受控环境汇总；外部测点缺失独立标注。生产只读核查，无切流、无资金写入。

**Tech Stack:** Dart/Flutter现有http及connectivity_plus，FastAPI/Pydantic，Python3.12标准库与curl。

依据：[已批准设计](../specs/2026-09-26-regional-measurement-design.md)。新工作树从b9eca8a4创建，并复制主目录80个既有改动文件作为只读输入快照；所有权只包含下列增量，回填前逐文件检查主目录hash。不得提交或覆盖继承的其他任务修改。

## A 客户端（独占移动端文件）

- [x] 新增`apps/mobile_flutter/lib/core/network_diagnostics.dart`及必要HTTP包装文件、测试`test/core/network_diagnostics_test.dart`；修改`chat_diagnostics.dart`、`chat_diagnostics_scope.dart`、`business_api_client.dart`及其诊断专项测试。精确HTTP契约见设计第4项。
- [x] 测试先红：正常200完整响应产生分母/正确桶，401属于http_4xx，超时属于timeouts，上传中新请求不被减掉，失败复用不可变sample_id，退出代次隔离，422回落原通道，历史摘要保留版本/时间，响应体错误不记成功、取消只计一次。
- [x] 实现有界固定桶与传输包装；透明保留HTTP headers/request/response元数据，无采集正文或任意路径；网络枚举来自已有connectivity_plus缓存，采集不得增加每请求平台IO。
- [x] 新专项及业务相邻88、最终受影响42通过；格式化、最终全analyze无问题、Flutter全量4034通过。schema2保留原来源，旧无来源schema1显式丢弃；日志/回执在本任务工件目录。

## B 服务端（独占接收契约及Python测试）

- [x] 修改`services/business-api/app/api/client_diagnostics.py`，新增`tests/business_api/test_network_diagnostics.py`，保留现有事件与frames行为。
- [x] 测试先红：networks-only合法202；完整计数/9桶约束；bool/任意文本/未知字段/非法时间/重复sample_id拒绝；16KB/鉴权/限流不变；stdout只输出闭合元数据，含版本与原时间窗。
- [x] 实现可选networks，响应accepted继续表示events数量，网络摘要不得当资金/活跃用户统计。不改变认证或限流。
- [x] 使用现有导出器生成OpenAPI；诊断115/契约相邻139通过，OpenAPI check通过；仅诊断路径改变，继承OTP等契约保留。

## C 工具（主代理独占探针/报告；telemetry_audit独占新增收集器）

- [x] 新增`scripts/network_probe.py`、`scripts/network_report.py`、`tests/infra/test_network_probe.py`及`test_network_report.py`。
- [x] 红用例证明成功/失败分母、curl无重定向/无不安全TLS、输出目录与目标验证、固定IP覆盖标注、统计分组/分位数、network摘要去重/冲突拒绝。
- [x] 实现有限次数/超时的串行GET与curl写出阶段，错误只保留数字码与固定分类；报告不自动推荐主区，不输出私密日志；路径/DNS绕过/代理标记分组问题已红绿修正，工具19通过。
- [x] 完成mock runner的受控CLI契约用例和真实公开路径短测；实际loopback TLS端到端未执行。工作站固定IP两目标均无成功样本，HK远端urllib自身路径3/3；一次新隧道尝试被自动审批policy拒绝、未创建。隔离这些网络视角，不能作独立运营商或SG同栈对照证据。
- [x] 授权增量：telemetry_audit独占新增`scripts/collect_network_diagnostics.py`、`tests/infra/test_network_collection.py`；先红后绿54专项、合计工具73通过，独立安全复审PASS。固定容器/strict jumper、远端闭合过滤、72h/100000行上限、16MiB/20000摘要内存门禁、原sample身份及独立meta；实际20000行/0摘要/truncated=true，不解释为零失败率。

## D 文档、现场及验收

- [x] 修正`docs/runbooks/singapore-edge-node.md`、`docs/adr/0086-media-storage-s3-backend.md`；新建`docs/runbooks/network-probes.md`和真实用户口径说明，更新`docs/runbooks/client-diagnostics.md`中已过时的spool描述。
- [x] 通过jumper严格主机/TLS验证，只读核对香港与新加坡；远端提取聚合数据，无原始日志/密钥/用户标识落盘。
- [x] 先规格符合性审查，再质量安全审查，修正后PASS；完整verify exit0结束23:42:22，API/worker2862通过/87条件跳过；final Flutter4034、全analyze0、mobile108/1条件跳过及工具73通过，repo policy再次PASS。verify早于客户端冻结，未变backend/infra证据复用，最终客户端/mobile与新增收集器门禁补齐。
- [x] 准备并核对仅归属文件的回填清单：80继承输入hash保护、两原干净tracked输入与HEAD复核，24项归属文件；[回填收据](../../verification/artifacts/2026-09-26/regional-measurement/integration-receipt.json)记录最终身份。阶段时间/红绿/限制见[验证报告](../../verification/2026-09-26-regional-measurement.md)；客户端未发布，不启动“新口径7–14天已完成”结论。

不创建新云资源、不迁主站、不变更DNS/线上TURN列表、不搬S3、不构建或发布APK/IPA。用户明确下一次更新包含客户端增量，当前交付源码、接收端候选、工具和证据。
