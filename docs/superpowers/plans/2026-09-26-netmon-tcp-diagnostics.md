# Netmon TCP 与网络诊断实施计划

> **For agentic workers:** Execute independent bounded client / netmon tasks in this session; primary agent owns receiver, integration, evidence and review.

**Goal:** 填补TCP握手与Release客户端网络失败可观测性盲区。
**Architecture:** 保留已有netmon/ChatDiagnostics/PerformanceMetrics，通过真实TCP probe和现有闭集诊断扩展、串行有界暂存实现。
**Tech Stack:** Python3/socket/system timers，Dart/Flutter/SharedPreferences，FastAPI/Pydantic。
**Approval:** 用户2026-09-26三项明确要求；不重设计认证、业务重试或Matrix。

## 1. Netmon（独立agent）

- [x] 只读定位现有服务器与大陆点netmon脚本、定时器、目标，按实际路径写候选和备份/恢复runbook。
- [x] 新增scripts/netmon_tcp_probe.py与tests/infra/test_netmon_tcp_probe.py：注入socket/高分辨率单调时钟，success、timeout、refused、真实耗时、success rate、bounded duration/attempts/log tests；先pytest红，再实现转绿。
- [x] 原监控增量接入独立每分钟调度；实际旧netmon仅探测TCP22，没有HTTP/TLS。保留它原样，候选在Linux/Windows真实环境测试，独立复审后安装，两轮实际分钟证据及回退/漂移检查。

## 2. 客户端（独立agent）

- [x] 以已推送main b18f0407为基线，审查并增量吸收旧b9eca8a4上的诊断WIP。禁止整文件覆盖当前统一trace。
- [x] 修改core/business_api_client.dart、chat_diagnostics.dart、chat_diagnostics_scope.dart，新增spool adapter并在main.dart接入；新增对应测试先验证失败。
- [x] 公共授权请求入口捕获generation与实际elapsed；只记录typed网络错误/401，不捕获文本。Release ChatDiagnostics原本已在认证scope开启，本轮保留并补失败记录；PerformanceMetrics现有条件保留。
- [x] 复用现有bounded queues与backoff，异步尾随持久化串行化；损坏/超大/过期、安全恢复、401、失败上传、session switch/old request/new event races必须覆盖；复审追加真实帧恢复/TTL ACK红绿。
- [x] 定向Flutter71通过，最终全量analyze/Matrix2153/full4479由主agent串行执行并通过，防止共享生成文件冲突。

## 3. 接收端（主agent）

- [x] tests/business_api/test_client_diagnostics.py新增network_request/timeout、network/401及隐私/旧协议断言；pytest先红。
- [x] services/business-api/app/api/client_diagnostics.py的Literal仅加network_request；不放开任意stage或字段。生成OpenAPI并检查契约。
- [x] 基于当前生产receiver实际镜像/源码确认必要增量；已使用现有API-only严格健康/备份/失败回退流程切换，不改worker/schema；实际健康与其余38容器不变门禁通过。

## 4. 集成验收

- [x] 规格审查PASS→质量安全审查PASS；netmon timer两处实证；无敏感字段或额外业务I/O。
- [x] Flutter analyze lib test、flutter test test/features/matrix、flutter test；API/Worker2912、infra201、mobile238通过；scripts/verify.ps1因缺.env真实exit1，已记录环境缺口及适用独立门禁与未变输入复用证据。
- [ ] 文档记录源码与生产分开、回退、限制、样本证据；用户已授权的Git集成push按最终门禁完成。
