# 后台布局与入账入口修复

用户已要求修复并展示HTML demo检查；沿用已批准人工补录业务流程，不改变金融状态或鉴权。当前工作区保留其他修改，Astra亲审，显式Terra执行，最多两人。先交可审查demo，本轮不执行真实入账。

- [x] U1 客服错位：Terra support_layout拥有admin-support-panel.js、styles/admin-modern.css、tests/admin-support-preview.html、独立新测试。字段组合成行，标题/反馈/动作区独立，适应窄屏；保持搜索分页、派发稳定幂等、移除确认。先红后绿，真实样式浏览器宽/窄视口验证。CSS只添加作用域规则，不改全局tokens。
- [x] U2 入账入口：Terra repair_entry拥有admin-wallet-repair-dialog.js、admin-manual-deposit-case.js、独立新测试、tests/admin-ui-review.html（整合demo）。显示步骤、可见禁用入账按钮与原因，预检通过且勾选后才调用execute；被阻断/已选单时保留人工补录入口。复用manualDepositCaseDialog并将其批准/预检操作区放在长证据前，保留审批、幂等和未知结果只查询。先红后绿；demo合成成功/阻断/无订单/窗口外流程。不得修改后端。
- [x] U3 Astra检查实际diff与调用链，运行前端全量、UI契约与必要门禁；浏览器实际走通确认入账及阻断分支，展示HTML demo并记录限制。后台专用UI无Flutter组件变更，registry/tokens保持不变。

U3已完成：Astra前端203项、UI契约、真实浏览器普通/阻断/人工补录、390px无溢出通过。未知结果跨流程入口禁用回归通过。[验证](../../verification/2026-09-13-admin-ui-followup.md)。
