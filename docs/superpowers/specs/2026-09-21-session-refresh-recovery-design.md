# 移动端刷新异常恢复与准确退出提示

状态：具体协议和实施已获用户批准，领域及质量安全设计审查通过。日期：2026-09-21。

设计、备选比较、状态机、安全边界及验收定义以 [ADR-0080](../../adr/0080-mobile-refresh-recovery.md) 为单一正文，避免两份规则漂移。

用户目标：后台返回不因正常网络/存储中断误退出；提示反映真实原因；不给用户增加操作负担。范围：移动业务刷新与安全存储、会话控制器、Matrix认证错误分类、兼容API与脱敏诊断。不是修改E2EE或放开多设备登录。

基线：ca4a306a，独立分支 codex/session-refresh-recovery-20260921，复用 .worktrees/chat-reliability-diagnostics。主工作区另有认证/金融未完成任务，禁止覆盖。之前2145的重启与权限修复仍在独立分支；交付整合时核验重叠的session_store/bootstrap，不能回退修复。

文件所有权预期：移动 core/business_api_client.dart、core/session_store.dart、core/session_bootstrap_controller.dart、诊断allowlist及相关测试；API identity刷新模型/路由、identity/tokens与models、matrix_login/matrix_sessions及测试；新增唯一扩展迁移、OpenAPI、任务和验证记录。实施时根据实时迁移heads取编号，不占用另一个任务已用的0072–0078。

评审顺序：领域/规格，然后质量安全；设计阶段两项已通过，正在按[实施计划](../plans/2026-09-21-session-refresh-recovery.md)进行TDD。代码完成后须再次评审实现；当前未构建或部署。
