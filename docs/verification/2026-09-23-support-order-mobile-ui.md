# 客服订单移动端 / HTML 验证

范围：批准的 support-order-workflow 计划 Task 3，主目录 main，不建分支、不提交、不安装、不构建 APK、不部署。截止验证时间 2026-09-23 11:52:42 +08；精确开始时间与主动执行时长未知，不推算。

## 实现与验收

- 充值/提现使用既有 CupertinoTextField 的 decimal 数字键盘、卡片、步骤条及文字 token；两步为填写金额→客服处理。金额输入页不显示客服或收款地址；参考估算优先，说明为 caption。提现金额修改通过“重新填写金额”返回首步，作废旧报价。
- 充值先检查官方支付配置可用性，只展示订单冻结的 official_payment 地址/二维码；二小时截止时间使用服务端 expires_at。凭证独立请求，持久化非秘密 txid 和幂等键；未知结果重启重试同键，不推断到账。
- 从 mine 恢复当前服务器订单，当前订单 ID 的本地草稿保留；已付款/凭证结果未知/已认领/逾期不显示普通取消。逾期仍可提交付款凭证供核对。页面可见时 15 秒刷新订单。
- 充值最终点钻、实际收到 USDT 与汇率只读服务端字段。提现 final_receive/final_rate/deadline/stage 加入已有状态缓存，重启不退回参考数值。支付授权、报价、冻结及请求接口未替换。
- HTML demo 使用示例数据，不发送真实订单或付款；充值按“下一步”进入付款信息/凭证示例，提现首屏使用同款大号参考金额摘要。

## 红 / 绿证据

测试先行观察：新增 support_order_workflow_test.dart 首次退出 1，金额键盘实际 TextInputType.text 而非 decimal；随后新增提现缓存断言退出 1，final_receive 实际 null；HTML 首屏测试退出 1，实际输入框数量 2 而非 1。均为预期缺失行为。

最后定向验证（全部退出 0）：

- `C:/src/flutter/bin/flutter.bat test --no-pub test/features/wallet`：126 通过，含重启恢复、付款凭证回包丢失同键重试、逾期 WAITING_PAYMENT/PAYMENT_VERIFIED/NEEDS_REVIEW、最终金额缓存及既有钱包安全回归。
- `C:/src/flutter/bin/dart.bat analyze` 四个修改的运行时钱包文件：No issues found。
- `node --test frontend/tests/phone-flows.test.mjs`：7 通过，含金额首屏、提现无目的地址、点击推进到凭证阶段但不宣称入账。
- `py -3.12 scripts/verify_ui_contract.py`：PASS，32 components / 398 screens。

日志与输入 SHA256：`artifacts/2026-09-23/support-order-workflow/mobile/` 下 wallet-tests.log、analyze.log、demo-tests.log、ui-contract.log、inputs.json。测试过程中旧三步/第二步编辑断言按批准的新两步流程调整；一次测试 import 位置错误已修正，最终 126 项覆盖该文件。

## 页面与视觉审查

浏览器实际打开 `http://127.0.0.1:4178/?screen=recharge-directory-directory`，检查首屏大号参考点钻、caption 说明，点击下一步，确认订单/网络/演示地址/二小时截止及凭证输入出现，未显示已到账。另检查 `?screen=wallet-withdrawal-default`，大号参考 USDT、说明及金额输入可见，没有收款钱包。固定手机画板宽度下布局无可见溢出。

注册表：packages/ui-contracts/changliao-component-registry.json 的 feedbackContracts `2026-09-23-support-order-workflow`（含 wallet-binding.js）及受委托补充的 `2026-09-23-support-admin-workstation`。后台源码由另一实施者拥有；本记录不替代其验证。

Figma 已退役：本次变更仅更新 HTML demo（frontend/index.html，以上 screen IDs）。

## 后续门禁

根实施者负责冻结全部模块后的全 Flutter/analyze、frontend 全量、scripts/verify.ps1、规格符合性→质量安全审查与服务端集成。上述定向通过不等于整个任务完成；未在真机验证、未生成或发布安装包、未执行真实资金或短信操作。

## Parent integration follow-up

The parent updated the existing wallet help dialog to remove the obsolete 1 point = 1 USDT wording, replacing it with 1 point = 1 CNY and reference-only estimates/final support settlement. The final wallet suite remained 126 passed. Four style notices in the newly added test were fixed with braces; the final whole-project analyzer reported no issues. The full Flutter suite passed 3,875 tests before this copy/style-only follow-up. The aggregate input manifest in the parent verification report supersedes this subtask's earlier per-file hashes for those two files.
