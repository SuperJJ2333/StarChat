# 帧预算诊断服务端生产发布

用户2026-09-23明确要求将四项优化应用到生产服务器，并排除安全、账号恢复、容灾剩余项目。实际服务端仅client_diagnostics.py有变更；其余Flutter优化保留源码，未授权推断已发布客户端。

基线：线上API e386b73d3a34351363b5248969331eba723b703dd0eac37265ee469198a1281a、客服修复a70e5191、HEAD1baaf36e、schema0087。候选.worktrees/diagnostics-release，唯一运行时代码差异client_diagnostics.py，335个API源码/迁移/依赖配置文件清单验证；不包含未发布红包过滤。

步骤：44定向测试与OpenAPI→读取实际Compose和335源码核对→0700远端备份及配置快照→离线单文件叠加镜像→无网络schema验证→隔离恢复、upgrade head前后原数据哈希保持→规格再质量审查→漂移检测→仅API切换，故障自动恢复旧镜像→双侧TLS、健康JSON、未鉴权401、有效/无效schema离线证明、其他容器与schema不变→发布记录。

文件所有权：本计划、docs/workflow/tasks/2026-09-23-diagnostics-release.md、docs/verification/2026-09-23-diagnostics-release.md、同日artifacts/diagnostics-release目录；恢复索引仅新增本任务条目。生产只增加任务目录与候选API镜像，重建business-api，私有备份留远端；不改DNS/数据库结构/worker/Flutter/官网。

已有客服版本全量verify2684/67通过作为未变基线证据，当前单文件44测试和隔离镜像证明覆盖增量；不重复无关Flutter或业务全量。公开请求不伪造生产会话，不代发真实诊断或资金操作。
