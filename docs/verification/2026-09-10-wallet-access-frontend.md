# 钱包页面 60 分钟验证：前端验证记录

范围：前端钱包入口、服务端 grant 状态读取、隐私模态层、普通操作凭证移除、配置流程及旧版兼容。未执行生产请求或资金操作。

## Red / green

- 先添加 API 测试：`getWalletAccess` 尚不存在，断言 `undefined != function` 失败。
- 先添加普通命令测试：实际字段含 `mfa_proof`，期望仅保留业务确认复选框，失败。
- 先添加 6 个 grant 控制器测试：实现不存在，明确控制器导出断言失败。
- 真实浏览器发现旧版 `RECENT_LOGIN_REQUIRED` 被新层误判权限不足；先补失败回归，再让 legacy 模式保留原认证错误处理。
- 增补 red/green：凭据轮换保留独立近期登录处理；TOTP_INVALID / TOTP_REPLAYED 保持钱包验证可重试，不误判权限不足。
- 最终 `node --test --test-reporter=spec frontend/tests/*.test.mjs`：145 tests，145 pass，0 fail。日志：`artifacts/2026-09-10/wallet-access-frontend/unit-green.txt`。

## 浏览器验证

通过 Codex 内置浏览器访问本地 `http://127.0.0.1:4589/tests/wallet-access-browser.html`，页面显示 PASS。覆盖：首次无敏感预取、原生最高模态 dialog、背景 inert、密码提交前同步清空、成功后读取、刷新不重复验证或重放、WALLET_ACCESS_REQUIRED 移除敏感 DOM、释放旧内容、Escape 安全退出、未配置仅显示安全设置且不调用金融读取。

访问 `http://127.0.0.1:4589/tests/manual-wallet-reauth-browser.html`，页面显示 PASS。模拟 `enabled:false` 验证旧五分钟 step-up 兼容、表单保留、失败命令不自动重放、人工再次提交沿用原幂等键。

无头 Chrome 启动命令被自动审批拒绝，原因仅为 `blocked by policy`；没有继续相同命令，改用受支持的浏览器工具完成上述测试。

## 边界

- 时钟单测覆盖 5 分钟后、59:59.999、60 分钟到期；刷新依据服务器剩余时间，不滚动延长；请求耗时保守扣除。
- grant 状态不落浏览器存储，不保存密码或验证码；BroadcastChannel 仅发送变更提示，收到后重新向服务器查询。
- 所有新钱包内容 API 经 guard；无效状态、页面离开或 dispose 后的迟到响应不能恢复内容；服务器仍负责最终授权。
- 服务端撤销由接口拒绝、30 秒只读状态检查及焦点/可见性变化时检查发现；本地已知 expires_at 到期立即移除内容。不是服务端推送撤销。
- 钱包凭据设置/轮换保留显式登录密码、当前/新秘密要求；普通资金操作保留原业务确认、幂等与按账号 journal。
- 仓库全量验证、领域与安全审查、生产部署由根协调任务负责；此记录不宣称已部署。
