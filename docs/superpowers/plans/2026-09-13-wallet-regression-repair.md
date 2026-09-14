# 钱包回归失败与两笔充值核查

用户已授权修复29项Flutter钱包失败和5项前端失败，继续Astra主审、显式gpt-5.6-terra执行。当前工作区，不回退前轮改动。生产交易仅只读诊断，实际资金写入不在本批操作内。

- [x] R1：Terra移动端复现29失败、定位业务/fixture差异；允许apps/mobile_flutter/test/features/wallet及lib/features/wallet、必要core接口测试，先报告根因再实施。保持支付密码、资金门禁、原幂等、E2EE、金额精度、个推；不删断言/跳过失败。验收针对性红绿+全Flutter+analyze，HTML同模块变更串行协调。主线程钱包64/64，最终Flutter2508/2508，analyze无问题。
- [x] R2：Terra前端复现5失败，允许frontend/tests/manual-wallet-panel.test.mjs、moment-reactions.test.mjs、source-contract.test.mjs及相关admin-dialog/moments/image-editor组件与既有token模块。先分类根因再实施；保留弹窗真实交互、事故不自动恢复资金、消息内容安全与颜色token规则。验收5失败全部消除及全node tests。主审批准primitives.css仅用选择器具体性替代!important；主线程npm test 184/184，图片编辑页面配色/工具选择通过，未做指针绘制像素比对。
- [x] R3：Astra只读生产诊断两笔txid/log0，核对运行镜像/schema、链上收据/候选订单/绑定/时间/审计阻断。报告精确事实，不用历史快照猜测；若代码缺陷另交Terra独占修复。第一笔原因代码与时间证明不匹配；第二笔超5分钟窗口，均未执行加款。
- [x] R4：Astra逐批实审diff和调用链，亲跑必要门禁，保留原始差异及输入hash，更新任务与证据。继承同环境未受影响通过门禁，按改变范围复跑；不把旧失败继续当无关。首次全量受外部并发改动影响失败，外部接口更新后亲跑全量2508通过；最终70边界通过。外部差异及未重跑的后端整套门禁单独如实记录。

交易：ab0ddd6a2723884b6ffe323ad4260aa1e25d61ecd398d5b20d35aee225a74c09 / 0；16f1f166b7b0e776f6c5529777e2eff11c9b9223b0b4ae906758f578118acbe3 / 0。
证据目录docs/verification/artifacts/2026-09-13/wallet-regression-repair/。最多两个执行代理，共享文件禁止并发改。

R1主审分批放行：先仅更新8个钱包测试/fixture以匹配已批准的独立页面与CAIBI/PIN入口。复现确定性报价错误后，允许manual_wallet_page.dart复用EXPIRED/CHANGED本地清理；未知结果必须保留原幂等键。随后旧官方地址安全断言揭示新intent路径缺少格式/校验和验证，允许manual_wallet_api.dart校验官方充值TRON Base58Check地址，失败禁止旧QR/复制展示。使用现有crypto依赖，不改提现绑定策略、账本、资金状态机或服务端权限。
