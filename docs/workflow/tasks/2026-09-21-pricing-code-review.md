# 2026-09-21 点钻/手机号/群主规则独立复审

## 恢复入口

- 用户授权：审查 ZCode 当前修改、及时修正、交付下一步 prompt；无部署/真实资金授权。
- 计划/规格：2026-09-21-pricing-auth-redpacket-group-program；ADR-0075～0079。
- 工作树：`.worktrees/pricing-review`，分支 `codex/pricing-review-20260921`；基础 commit `3d9689971002bdab9dfa70eac63477308fb116b1`。主目录其他任务修改保留。
- 所有权：本任务仅修改复审发现问题涉及的后端、测试、生成 OpenAPI 与本任务记录；不修改 Flutter 或后台 UI。
- 报告：`docs/verification/2026-09-21-pricing-code-review.md`。
- 下一步 prompt：`docs/workflow/prompts/2026-09-21-zcode-next-step.md`。

## 阶段证据

|阶段|时间/证据|结果|
|---|---|---|
|冻结输入|2026-09-21 22:18:20 +08:00，input-snapshot.json|64 个未提交文件，独立树复审|
|基线复现|baseline-red.log|26 failed / 1 passed，exit 1|
|专项修复|focused-root.log|中间态 131 passed，exit 0|
|PostgreSQL|postgres-migration.log / postgres-concurrency.log|实际迁移 0001→0078；FX/OTP 32 并发，exit 0|
|全量首轮|verify-full.log，1704.49s|2320 passed / 17 failed / 58 skipped，exit 1，保留失败记录|
|失败模块回归|full-failures-fixed.log，23.16s|55 passed；只补汇率/权威群主测试前置，未放宽断言|
|完整后半段门禁|verify-remaining.log|mobile 84、UI contract、AST、迁移、OpenAPI、Compose 通过；不冒充完整 verify exit 0|
|最终改动集合回归|final-changed-tests.log，101.04s|203 passed / 0 failed，exit 0，1 条既有弃用警告|
|安全回填|applied-changes.json / final-source.json|40 个文件逐项原输入校验后回填；614 个输入与主目录无实质差异；主目录 OpenAPI 再查通过|

精确主动耗时无法从聚合工具输出还原，不估算；输入冻结至最终证据的墙钟可从 JSON 时间复核。未部署、未打包、未进行双端真机验收。

2026-09-21 23:16 +08:00：代码回填主工作区完成，相关测试进程已退出；隔离 PostgreSQL 验证容器已停止并自动删除。未进行生产连接、真实汇率调用、短信或资金操作。下个可执行步骤为按下一步 prompt 的第一批补齐持久协调/恢复流程；真实供应商和设备缺失不允许标为验收通过。

## 保留的阻断项

群主转让端点安全关闭，待持久协调；人工充值执行与案件登记待持久绑定/恢复；真实 SMS、后台三页与 Flutter 仍待完成。下一阶段先读报告与 prompt，不恢复已证实有缺陷的实现。
