# 请求失败细类与服务端时间线

## 恢复入口

- 用户授权：接受上一回复“补充不含用户信息的错误细分类及请求阶段，再关联服务器时间线定位”，允许实施代码、验证、只读服务器调查；服务候选准备完成后单独按发布流程交付。既有Debug保留数据安装授权继续用于本次诊断增量，正式Android/iOS分发未授权。
- [设计](../../superpowers/specs/2026-09-27-network-failure-diagnostics-design.md)、[计划](../../superpowers/plans/2026-09-27-network-failure-diagnostics.md)。current-state恢复入口已读取；前轮Debug2186/PHONE API1aa6是历史事实，新生产快照由server owner重读。
- worktree：C:/Users/Administrator/.codex/worktrees/network-failure-diagnostics/StarChat；native工具创建成功，HEAD91292717b93a8f28bdd4e7d4cf30900c5c2dc918，移动基线来自本轮已交付Debug，后端tracked基线较旧，需要精确非秘密依赖/生产源预检，不将旧仓库当新live。
- 文件归属见计划：client仅network请求与business constructor；root仅chat spool/collector/report/文档；server仅契约/tracing/newtimeline/专属API测试及OpenAPI。不同owner不得同时写同文件。
- 当前：设计方向用户已确认，实施前细化完成，准备TDD；server只读现场调查同步进行。初始用户响应确切时刻未知，不编造总工时。
- 下一条：客户端red分类/phase/request UUID测试；root准备spool接口；server回传freshlive安全源码/日志保留及最小log sink信息。

## 验收台账

| ID | 场景 | 当前状态 | 局限 |
| --- | --- | --- | --- |
| N01 | 错误细类和可信阶段，8秒预算/迟到响应 | 设计/TDD待 | HTTP接口不能准确分DNS/TCP |
| N02 | 每次请求随机ID、401重试独立、无身份/正文 | 设计/TDD待 | 未随新包安装就没有新字段 |
| N03 | 闭合兼容接收/spool限额/422恢复 | 设计/TDD待 | 新API尚未授权发布 |
| N04 | bounded非阻塞服务端时间线、ASGI边界 | 设计/TDD待 | send返回不等于手机收到 |
| N05 | 闭合采集/join与历史58/15原因 | 只读调查中 | 无ID的旧摘要不能补造 |
| N06 | 实际构建/候选/验证/安全回填 | 待门禁 | 真机及iOS环境另列 |

## 证据与交接

非Git验证及临时工件仅docs/verification/artifacts/2026-09-27/network-failure-diagnostics/。部署源码/config/容器/schema事实须重读，保留PHONE/S3/诊断，旧d392/e880候选不得覆盖live。原始log/env/数据库/账户或IP不导出。本设计不新增未登录入口或认证策略，受保护金融/Matrix规则不改。阶段开始/结束带+08和真实exit/hash；完整门禁等价输入仅执行一次。
