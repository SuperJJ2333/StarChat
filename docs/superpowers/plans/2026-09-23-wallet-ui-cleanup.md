# 2026-09-23 红包与充值界面限定调整计划

用户本轮明确授权三个界面调整及后续 debug 构建安装；本子任务只实施与专项验证，构建安装交由主协调任务。沿用 [客服订单批准计划](2026-09-23-support-order-workflow.md) 的既有组件与业务网关，不修改金融规则。

- [x] 发红包页去除静态手续费、限额、人数说明；仅保留退款提示并固定在页面底部。保留输入占位、提交校验、失败提示与恢复动作。
- [x] 充值第二步二维码居中，复用 WalletQrExporter / GalleryQrExporter 和既有 iconActionButton 保存到系统相册；反馈保存中、成功、权限错误，移除二维码下静态说明。
- [x] 收款地址标签简化，当前充值订单地址右对齐紧邻复制图标；复制完整地址。
- [x] HTML demo 与 registry 同步；先红测试，再实现、绿测试与 analyze/UI contract/frontend 门禁。
- [ ] Root 集成候选完整检查、debug 构建、固定签名重建与保留数据安装；真机确认保存权限与视觉。

所有权：两页 Flutter 及对应测试；frontend/src/screens/{finance,phone-flows}.js、对应 frontend 测试；packages/ui-contracts/changliao-component-registry.json；本任务独立计划/任务/验证记录。不编辑其他 dirty 优化文件、current-state 或版本。
