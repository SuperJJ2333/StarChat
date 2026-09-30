# 账号与个人信息 HTML 审阅验证

日期：2026-09-26，Asia/Hong_Kong。用户明确先审阅 HTML demo，再实施正式页面。

## 候选与范围

- 页面：[独立 HTML](../../frontend/reviews/account-ui-20260926.html)，自包含 CSS/JS/token 快照及现有登录 PNG；可离线打开。
- 本地预览：`http://127.0.0.1:4186/reviews/account-ui-20260926.html`；总览为个人信息、设置、登录；页签和手机内导航提供账号安全、聊天、更换密码及手机号/邮箱绑定页面。
- HTML SHA256：`b0a20fba79dcd11845fa57aabb52696c6606553167f80719cee063abeffce45e`。
- 基线 HEAD：`b9eca8a419614112b085439445b7fd031027a740`，存在其他任务的未提交修改，未覆盖或提交。
- 仅新增审阅稿与文档/证据；未改 Flutter、业务 API、现有 token/registry/catalog，未构建 APK/IPA、未安装、未发布。
- Figma 已退役：本次变更仅更新 HTML demo（`frontend/reviews/account-ui-20260926.html`）。

## 验收

| 需求 | 浏览器观察 |
| --- | --- |
| 移除 3/12、0/20 | 页面不显示数字计数；demo 对齐当前服务端 64/140 长度约束，安装版计数差异待正式实施核对 |
| 昵称/个性签名固定左标签 | 空值、有值、保存成功、刷新后均存在独立 label；失败保留草稿 |
| 设置分组 | 账号→账号安全→手机号/邮箱绑定更换、改密码；通用→聊天→好友邀请自动入群开关；失败维持原状态 |
| 登录忘记密码 | 与账号安全改密码入口显示相同验证码表单；邮箱和大陆手机号分别可走演示流程 |
| 预先绑定 | 每个所选渠道独立检查绑定前提；两者皆未绑定或所选渠道未绑定均不能进入新密码步骤 |
| 错误与状态 | 未获取/错误/过期验证码、网络失败、发送后更换目标、密码不一致均阻断；取消提交后旧延迟回调不再显示成功 |
| 换绑 | 手机首绑先验证已有邮箱；邮箱首绑审阅方案先验证已有手机；完成后账号安全脱敏摘要更新 |
| 设计一致性 | 手机主题按现有移动覆盖；白底操作按钮、绿色图标、渐隐横线；登录背景和模式切换保留；浅/深色及 320/375px 无横向溢出 |
| 模拟边界 | 演示码 123456，无外部请求/真实验证码/真实会话/账号写入；密码不写入持久存储，登录及完成步骤清空密码 |

## 命令与证据

全部命令通过 PowerShell 7，UTF-8 无 BOM，Python 环境 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`。

| 命令 | 真实结果 | 日志 |
| --- | --- | --- |
| `node docs/verification/artifacts/2026-09-26/account-ui-review/browser-review.mjs` | 最终 exit 0，16 个检查通过，0 浏览器异常，0 外部请求 | [结果 JSON](artifacts/2026-09-26/account-ui-review/browser-results.json)、[日志](artifacts/2026-09-26/account-ui-review/browser-run.log) |
| `npm test`，cwd `frontend/` | exit 0，299 passed，0 failed/skipped | [frontend 日志](artifacts/2026-09-26/account-ui-review/frontend-tests.log) |
| `python scripts/verify_ui_contract.py` | exit 0，32 components / 403 screens PASS；只证明未变正式 registry 一致 | [契约日志](artifacts/2026-09-26/account-ui-review/ui-contract.log) |
| 文档 UTF-8/本地链接和 JS 语法检查 | 由最终文档检查日志记录实际结果 | [静态检查](artifacts/2026-09-26/account-ui-review/static-check.log) |

环境：Windows 10.0.19045，Node v22.22.2，Chrome 154.0.8037.58，PowerShell 7.6.5，Python 3.11.11。token 输入 SHA `498239310fb524b823182ce5c066a6354a78fb696114257bf03cb347dd3112ae`；既有依赖锁和相关输入 SHA 见静态检查。

首轮浏览器 exit 1：验证器对相同 URL 的 `goto` 未重新加载，沿用了上个网络失败情境；修正验证器的情境隔离后通过。保留[首轮日志](artifacts/2026-09-26/account-ui-review/browser-first-run.log)。这不是正式 BUG 的 red/green 证据。本阶段无 Flutter/后端实现，不声称正式修复或全量门禁通过。

已预读 `scripts/verify.ps1`：它会执行配置渲染和全量后端/迁移检查；本任务为独立审阅稿，未改其生产源码输入，因此本轮不执行该整套脚本、Flutter analyze/test 或平台构建。相关正式实施门禁留至用户批准后的候选，不能把本轮 frontend 验证替代它们。

## 视觉与审查

- 已查看[浅色总览](artifacts/2026-09-26/account-ui-review/overview-light.png)、[深色总览](artifacts/2026-09-26/account-ui-review/overview-dark.png)、[账号安全](artifacts/2026-09-26/account-ui-review/security-light.png)、[更换密码](artifacts/2026-09-26/account-ui-review/password-light.png)、[窄屏深色](artifacts/2026-09-26/account-ui-review/profile-mobile-dark.png)。
- 先规格符合性审查：发现并修正移动色层、白底按钮、分割线、逐渠道绑定状态、密码上限及好友邀请范围。
- 再质量/安全审查：发现并修正延迟提交回调、登录密码清空与逐渠道找回阻断，补充对应浏览器回归。DOM 用户值转义、无外部调用、模拟声明和密码存储边界已检查。
- 用户视觉批准尚未取得；真实验证码/绑定/密码更换/设备持久化均未验证。

## 交接

- 保留本任务预览服务端口 4186；`node scripts/serve.mjs` 由本任务启动，exec session 41724。不要关闭其他任务进程。
- 下一步：用户审阅具体页面并提供修改/批准反馈，再建立正式实施计划和认证 ADR。现有邮箱 reset 是链接流程，手机 OTP reset 和已登录邮箱换绑需补契约；保留业务刷新会话撤销、24h 提现冷却和 E2EE 边界。
- 本地设计记录与可确认的浏览器检查时段为 14:13:54 起至最终检查完成；此前准备起点未知，不从文件时间估算精确总工时。文档、只读调查和 HTML 编写并行。
