# 帧预算诊断生产发布任务

授权：用户明确将四项优化的服务器改动发布，受保护剩余项暂不处理。关联计划 ../../superpowers/plans/2026-09-23-diagnostics-release.md。
状态：预备。工作树.worktrees/diagnostics-release，基线1baaf36e，运行时只改API诊断文件。精确起点未知，18:33工作树建立；44项测试1.18秒、OpenAPI通过。下一步备份/隔离验证/审查后API切换。客户端三项优化及帧采集端均需未来客户端构建；本任务不宣称它们已在旧APK中生效。AWS/S3/TURN和安全恢复提案不在范围内。

证据目录 docs/verification/artifacts/2026-09-23/diagnostics-release，远端私有目录/opt/starchat/releases/diagnostics-20260923。不得下载私有配置或备份。

## 最终状态 2026-09-23 19:00 +08

服务端已发布并验证：API e2577705bc27，schema0087，23其他容器未变，双侧HTTPS正常。详见[报告](../../verification/2026-09-23-diagnostics-release.md)。44定向+5回退测试、335文件证明、136表217441行隔离恢复通过。临时隧道已关闭，恢复容器已停止。下一步仅在用户另行要求客户端交付时构建/发布新客户端；受保护提案遵用户要求暂缓。
