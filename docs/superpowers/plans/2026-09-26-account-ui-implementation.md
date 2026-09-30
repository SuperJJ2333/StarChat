# 账号与个人信息 UI 正式实施计划

> **For agentic workers:** Use subagent-driven-development with test-first red/green and specification review before quality/security review. Each owner edits only its declared files.

**Goal:** 将用户已批准 demo 的四项需求落实为真实 Flutter 页面、兼容业务接口及一致 HTML catalog。

**Architecture:** Matrix保留通信与密钥边界；身份业务服务提供已验证绑定、恢复OTP及邮箱换绑的唯一权威。Flutter共用验证码更换密码页与gateway；设置仅重组入口、复用现有手机换绑和群偏好接口。复用既有OTP表/事务callback，无破坏性迁移。

**Tech Stack:** Flutter 3.44.9/Dart3.12.2、FastAPI/Python3.12、SQLAlchemy2、既有Outbox/审计、HTML custom elements/语义tokens。

用户2026-09-26批准审阅稿并要求正式实现，此计划按该批准执行；关联 ADR-0085 与审阅设计。工作树 `C:/Users/Administrator/.codex/worktrees/account-ui-implementation/StarChat`，分支 `codex/account-ui-implementation`，基线 `b9eca8a4`。原目录的诊断/移动并行修改保留；本任务不部署或发送真实验证码。

## Task 1：认证接口与领域服务（后端代理独占）

**Files:** `services/business-api/app/modules/identity/phone.py`、新 `account_credentials.py`、`recovery.py`（仅复用/提取既有改密应用操作所需）、`services/business-api/app/api/identity.py`、注册邮件OTP装配/worker处理相关文件；`tests/business_api/test_account_credentials.py` 及新API测试。禁止编辑 Flutter/frontend/注册表/OpenAPI输出。

- [x] 写失败测试并运行：`py -3.12 -m pytest tests/business_api/test_account_credentials.py -q`，证明未实现双渠道验证与邮箱绑定；记录具体失败和源码输入。
- [x] 实现 request/verify/reset 及邮箱四步换绑：
  ```python
  request_password_code(channel="email", target="bound@example.test")
  proof = verify_password_code(channel="email", target="bound@example.test", code=code)
  reset_password(token=proof["reset_token"], new_password="new-password-123")
  ```
  使用既有OTP事务回调；ACTIVE/verified/current binding/user约束、5分钟证明、原子消费、用途隔离/限频与供应商故障均由服务端保证。改密调用公共身份应用操作保持refresh撤销、24h hold、审计/Outbox。
- [x] 测试错误/过期/重放/目标变更/跨用户/非ACTIVE、未验证、邮件SMS隔离、绑定唯一性及旧链接兼容；跑identity/phone/recovery相关回归。
- [x] 输出精确接口字段、每项red/green命令与日志；先领域/规格审查再质量/安全审查，不部署/真实发码。

## Task 2：Flutter页面与公开gateway（移动代理独占）

**Files:** 新 `apps/mobile_flutter/lib/core/account_credentials_gateway.dart`、`core/business_api_client.dart`；新 `features/auth/password_change_page.dart`、`features/auth/email_rebind_page.dart` 和相关controller；`features/auth/login_page.dart`、`features/profile/profile_page.dart`、`app_home.dart`；对应新/受影响 Dart tests。不得编辑backend/frontend/registry/docs。

- [x] 写失败widget/controller/client测试，运行 `C:/src/flutter/bin/flutter.bat test test/features/auth/account_credentials_test.dart test/features/profile/profile_account_ui_test.dart`（最终文件名由所有权报告确定），确认缺失入口/固定标签/真实gateway行为失败。
- [x] gateway语义冻结为请求码、验证并返回resetToken、提交改密、读取绑定摘要、邮箱四步；HTTP路径按ADR-0085。公开请求8秒预算，不自动重放，不持久化验证码或密码；已登录调用带授权且受当前用户约束。
- [x] 个人信息固定左标签、计数不显示，保持头像/邀请/拍一拍/邮箱及权威保存反馈。设置账号→账号安全、通用→聊天，聊天调用现有群偏好API，保存失败恢复原状态。
- [x] LoginPage忘记密码与账号安全使用同一个PasswordChangePage。邮箱/手机验证码成功才进入新密码；提交成功撤销旧客户端会话、保留聊天历史再返回登录。邮箱页原渠道证明→新邮箱验证，保存后返回权威脱敏摘要；手机号复用PhoneRebindPage。
- [x] 跑focused tests、`flutter analyze`；提供测试和组件名/HTML tag映射、注册表需要的props/states/tokens给frontend代理。

## Task 3：正式HTML catalog及注册表（前端代理独占）

**Files:** `frontend/src/screens/profile.js`、`auth.js`及新 `account-credentials.js`；`frontend/src/catalog/screens.js`、必要styles/shared组件；`packages/ui-contracts/changliao-component-registry.json`；frontend新测试。不要改已批准review单文件、Flutter/backend/docs。

- [x] 新失败测试验证默认profile固定label无counter、settings两组、两条密码入口同renderer、未绑定/错误状态：`node --test tests/account-credentials.test.mjs`（cwd frontend）。
- [x] 按批准稿在正式catalog展示个人信息、账号安全、聊天、邮箱绑定、更换密码两步骤/成功/失败。复用注册共享组件及移动token、渐隐分割线、白底图标按钮、登录背景，不引入第二套样式系统。
- [x] registry在UI实施前登记此次反馈合同与新增Flutter/public组件及HTMLtag、props/states/token映射；根据最终真实widget路径对齐。计数动态由实际catalog导出，不让测试旧数量阻塞。
- [x] `npm test` 和 `py -3.12 scripts/verify_ui_contract.py` 通过，记录catalog IDs及截图可见入口。

## Task 4：集成和兼容门禁（主代理独占）

**Files:** `packages/api-contracts/openapi/liuhetong-v1.yaml`（JSON兼容YAML导出）、`docs/workflow/tasks/2026-09-26-account-ui-implementation.md`、本ADR/计划、verification报告、必要runbook/当前恢复索引及仓库边界测试数量调整。

- [x] agent阶段先规格/领域检查，再独立质量/安全检查并修复实质问题。
- [x] `py -3.12 scripts/export_openapi.py` + `--check`，核对路由/字段与客户端测试；无SDK契约破坏，无密钥/凭证泄漏。
- [x] 最终候选运行focused/auth tests、frontend全量、Flutter analyze和全量test；预检后运行 `pwsh -NoProfile -File scripts/verify.ps1`。仅对相关输入变化补跑，不重复未变的等价门禁。
- [x] 做必要原生登录相关编译检查；记录Android/iOS执行平台差异。未授权发布/安装或真实OTP验收不伪装为通过，不阻断可完成源码工作。
- [x] 保留源SHA/锁文件/工具版本/命令exit，文档与契约一致。通过审查和门禁后将本任务delta安全回填原工作区：先`git apply --check`，不整文件覆盖已有诊断改动；若有交叉修改按块集成并补相关回归。

## Task 5：交付

- [x] 更新current-state任务索引，记录实际实现/验证/未发布状态，列出HTML catalog路径与已批准设计一致性。
- [x] 用户收到简短结果：功能、真实测试数、源码位置、是否有包/生产变更、仍需真机/短信通道验收项。保留工作树/分支及回退信息，不删除其他任务资源。
