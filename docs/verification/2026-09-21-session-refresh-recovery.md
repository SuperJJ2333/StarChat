# 凭证刷新异常恢复：验证与交付边界

## 原因和改动

实际事件的直接原因为TOKEN_REUSE：服务端已经消费旧刷新令牌，客户端再次提交它触发撤族。现场尚缺旧客户端阶段日志，不能确定原事件是哪一种响应/持久化失败。实现已针对这些明确存在的窗口做故障注入修复，不把假设当成现场证据。

- 客户端先在同一安全存储会话记录写入256位随机操作凭据，再请求刷新。预写失败不发送；响应丢失重试同一操作；保存结果未知时重读确认；进程重建可恢复pending。
- 服务端在同一事务只消费一次父令牌；匹配操作恢复原子令牌，不延长其有效期；不同操作重放仍拒绝。恢复前检查族/设备/账户/管理域，明确登出/封禁/替换不能被恢复。
- 旧操作的子令牌已推进时返回409供客户端重读，不撤销新会话；已过期移动凭证用独立REFRESH_TOKEN_EXPIRED。
- 仅明确终止错误清除业务认证。临时网络/存储错误、未知401、旧API422保留会话；后台停止定时检查，重试限额及退避。单请求20秒预算不取消共享刷新保存结果。
- 退出文案区分重新登录、凭证校验异常、过期和账户限制。Matrix接口不再把一般失效原因统称其他设备登录。
- 诊断增加闭集阶段、重试次数及前后台状态，使用独立随机诊断UUID，不传刷新操作凭据/令牌/真实账号设备/原始异常/聊天内容。无认证时客户端批次不能保证上传；服务端对已提交TOKEN_REUSE撤销记录固定日志，并保留原数据库撤销原因。不是完整native crash采集。

## 授权与审查

用户已明确批准[ADR-0080](../adr/0080-mobile-refresh-recovery.md)及实施。[计划](../superpowers/plans/2026-09-21-session-refresh-recovery.md)。领域设计→质量安全设计→服务端领域→服务端安全→客户端领域→最终安全审查均已完成，无未解决P1/P2。领域审查提出的已推进子令牌优先分类及20秒调用预算均补测修复；迁移重复升级也有红绿证据。

静态评审不能替代测试，以下只写实际执行结果。

## 已完成专项证据

证据目录：[session-refresh-recovery](artifacts/2026-09-21/session-refresh-recovery/)。测试环境Windows、Python3.12.10、Flutter3.44.9/Dart3.12.2；源文件SHA及依赖锁身份见[candidate-source.json](artifacts/2026-09-21/session-refresh-recovery/candidate-source.json)和[任务](../workflow/tasks/2026-09-21-session-refresh-recovery.md)。

| 范围 | 红绿/结果 | 日志 |
| --- | --- | --- |
| 服务端恢复/失效/Matrix/API | 实现者先红后绿；最终恢复+旧令牌+管理员63 passed，exit0 | server/green-expiry-code.txt |
| 服务端身份全量（中间快照） | 309 passed、10 PG条件跳过、1既有Starlette弃用提示，exit0；后续增量由专项覆盖 | server/identity-full.txt |
| 真PostgreSQL并发 | 8 passed，exit0；Docker postgres16.9-alpine隔离库，含4个相同操作并发只产1个子令牌 | server/pg-green.log |
| 迁移保留数据往返 | 重复列红测后修复，15 passed，exit0；降级保留字段/值，重新升级幂等 | server/green-migration-reupgrade.txt |
| 客户端故障注入 | 初始8 failed/2 passed；最终16 passed，exit0；含20秒预算红绿 | client-red.log、budget-red.log、client-final-focused.log |
| 相邻会话回归 | 74 passed，exit0（最终预算增量前；最终全量另记） | client-focused.log |
| 服务端诊断 | 6个新阶段先红；34 passed，exit0，1既有Starlette弃用提示 | diagnostics/red-server.log、diagnostics/green-server.log |
| 客户端诊断/独立上传 | 13 passed，exit0 | diagnostics/green-client.log |
| Flutter分析 | No issues found，exit0 | analyze-final.log |

Flutter最终全量3757 passed、0 failed，exit0，测试3分24秒。完整verify首次退出1：API/Worker 2300 passed、1 failed、48条件跳过（24分56秒），唯一失败为发布基线仍将0071写为最新迁移。仅更新该测试为0080并保留0071父链及既有祖先断言，迁移/基线重跑17 passed、exit0。依照移动交付工作流复用未变输入的已通过门禁，不重复整套后端；续跑原verify剩余步骤exit0：移动边界84 passed，UI契约32组件/375页面、AST241文件、迁移、OpenAPI及Compose全部PASS。合并证据覆盖API/Worker 2301通过、48条件跳过；不是声称首次verify退出0。日志：verify.log、migration-baseline-green.log、verify-tail.log，续跑脚本verify-tail.ps1保留。首次Flutter专项因以前测试缓存指向已撤销的T:映射失败，恢复本工作树T:映射后重试；环境错误未当作功能红测。中间analyze发现4项花括号提示，已修复后复跑无问题。

## 发布和真实设备边界

- 本次无生产更新、无生产迁移、无Android/iOS新安装包。代码验证不表示用户当前Android0.3.102已经生效。
- 必须先部署兼容服务端及扩展迁移，再发布移动新包。旧App不携带恢复操作凭据，不能仅靠服务器升级获得完整保护；已撤销的旧会话不复活。
- iOS2145权限/重启修复仍在独立分支，交付整合必须保留；本轮没有重做其构建或假定出口合规已完成。
- 主目录还有未提交0072–0078及认证/金融改动；本分支0080接0071，合并时必须解决迁移图和重叠文件，不将分支全量覆盖主目录或生产。
- Android/iOS真机断网、后台返回、系统重启和安全存储恢复仍需新包验收；不能承诺所有情况下永不退出，真实撤销/过期/重放仍要求认证。

## 时间与清理

初始精确起始时间未完整采集，不编造总分钟。22:57+08设计初稿，23:17+08客户端74项专项结束，23:19+08OpenAPI导出，23:22起完整门禁执行。所有计时以命令退出及日志为准。临时T:映射与starchat-refresh-test-20260921隔离PostgreSQL容器为本任务所有，全部依赖进程结束后清理；不接触生产数据。

清理完成：本任务隔离PostgreSQL容器（核对完整ID后移除）和T:映射已移除；所有测试命令已退出，无生产资源变更。
