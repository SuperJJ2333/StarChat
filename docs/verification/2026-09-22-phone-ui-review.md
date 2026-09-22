# 手机与钱包 23 屏 UI 优化

范围：用户授权优化现有 HTML demo；复用现有组件，不新建组件，不部署、不发送短信、不进行资金操作。Flutter 页面未实现或验证。

## 修改与审查
- 修复 field 返回值使用错误：手机号、新手机号、充值金额和凭证输入框缺失且出现 undefined。
- 修复 catalog 短状态名与渲染器比较值不一致：错误、冷却、注册等待、换绑和转让完成现在正确显示。
- 认证页面沿用 c-brand-mark、c-auth-form、c-form-field、c-form-help/error；验证码复用 app-secondary-button；主操作沿用 app-action-button。
- 沿用现有 token 和布局类，统一间距、数值对齐、换行和触控区域；不新增 custom element、token 或组件注册。
- 移除真实测试手机号、面向用户的内部状态码和虚构 IP 封禁描述；充值历史示例与人民币计价一致。
- 红包限额重试通过普通容器控制可见性，避免对严格组件写入未授权 hidden 属性。测试跟随用户可见行为检查容器。
- 样式层测试按 URL pathname 核对顺序，允许既有缓存版本参数，仍保留全部顺序与路径断言。

规格检查：0.5% 手续费、0.1% 群主收益、仅本群满 10 人免手续费、未完成转让不显示新群主、申请不等于到账均保留。质量检查：无新增组件、无真实请求、用户输入框可见、完成状态正确。

## 验证
- 首次浏览器复现 phone-login-phone-error 仅 1 个输入框，预期 2，exit 1；修复后 2 个，exit 0。
- node --test --test-reporter=spec：245 passed / 0 failed，exit 0，含新增 5 项页面回归。
- py -3.12 scripts/verify_ui_contract.py：PASS，32 components / 398 screens。registry 和 token 未改。
- Edge/Playwright：23 屏逐屏截图，图库 pageerror 0，输入/section 横向溢出 0；结果及截图位于 artifacts/2026-09-22/phone-ui-review。
- 已目视核对登录错误、充值目录、转让完成截图。
- 本次仅 HTML demo 与测试改动，未重新执行 scripts/verify.ps1 后端/Flutter 全仓门禁；不能将历史门禁视为此次全仓通过。无真机和生产验证。

## 入口
http://127.0.0.1:8080/index.html?screen=phone-login-phone-error
http://127.0.0.1:8080/index.html?screen=recharge-directory-directory
http://127.0.0.1:8080/index.html?screen=transfer-transfer-completed

Figma 已退役：本次变更仅更新 HTML demo（frontend/src/screens/phone-flows.js 与 finance.js）。静态演示的登录/充值/换绑不代表真实业务 API 已接通。下一步在用户确认演示布局后，按既有契约实现 Flutter 页面与真机验收。

## 用户反馈后的页面复用调整
- recharge / fx 直接复用 walletBindingDemo 的充值页面、导航与返回交互；以 depositContent 承载人工充值/参考汇率内容，避免启用旧自动充值流程。
- commission 直接复用既有 redpacket 详情渲染器，在原详情内容后追加费用摘要，不另造红包页面。
- transfer 使用钱包卡片相同内边距/圆角 token，保持中性背景；隐藏技术阶段，仅展示用户可理解的结果。没有新增组件。
- 现有 Flutter 入口：群资料 → 转让群主 → 选择成员 → 确认；建议原操作页呈现处理中/待核对，成功后返回更新群资料。独立图库样例不等于 APP 新路由；Flutter 尚未改造。
- fx 建议作为充值/提现金额旁参考信息，不新增导航入口；现有 demo ID 保留作状态验收。
- 复验：245 tests passed；UI contract PASS（32 / 398）；23 屏与图库无 pageerror、无检测到横向溢出。截图已更新，目视检查充值与红包详情。
