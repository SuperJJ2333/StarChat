# 钱包绑定与点钻提现 UI 源码交接

记录：2026-09-11 00:22 +08:00。分支 `codex/wallet-binding-payment-20260911`，工作树 `.worktrees/moments-im-mi6-20260910`。主计划 [wallet-binding-payment](../superpowers/plans/2026-09-11-wallet-binding-payment.md)。分工仅拥有两个钱包 UI 文件；客户端 API、支付 helper、后端与 HTML 由其他负责人实现。阶段开始精确时间未记录，耗时未知；00:22 已释放 UI 文件用于 root 冻结构建。

## 修复与集成

- `wallet_page.dart` 改为嵌入 ManualWalletPage 概览；AppHome 已有的“钱包”导航栏保持唯一。外部测试使用的 WithdrawalOrderPoller 原样保留。
- `manual_wallet_page.dart` 使用独立 overview/binding/deposit/payout route，移除 segmented tabs。卡片右上绑定/改绑图标；无 ACTIVE 绑定、配置未成功读取、绑定状态未刷新或功能未就绪时充提灰色 disabled，回调为 null，不能触发跳转或请求。
- 点钻新提现还要求 `caibi_payout_enabled`、`conversion_enabled`、`manual_payout_enabled`、`manual_payout_execution_enabled` 明确为 true。旧服务器缺少新 capability 时安全禁用，不能把点钻表单误提交成 USDT 支出。
- 提现页显示服务器 `caibi_available`，入页、回前台、点击全部、提交/取消后刷新；前台且当前可见的钱包/提现页每15秒刷新，in-flight共享同一Future，后台与非当前页面不发轮询，dispose取消timer。全部提现先读服务器再填完整两位金额。比较金额使用BigInt，格式归一为字符串，未使用double处理资产。
- 新quote保存CAIBI来源和quote ID；旧记录未标来源时按原USDT报价恢复，不把原六位金额转换为点钻。已有充值/提现另设恢复入口，主充提按钮的门槛不会被恢复需求放开。
- PIN通过 root 的 wallet_payment_flow.dart 公共helper完成；授权显示不可变quote的fundingAmount及目标掩码。登录wallet/payment scope初始化捕获，弹窗前与proof后核验。新的PIN取消不会发提现命令，并清除仅本次创建的payout草稿，保留报价。proof不落盘。
- 未知提交结果按原key先无proof恢复，只有服务端PAYMENT_PIN_REQUIRED/SETUP_REQUIRED才重新授权；不得改key或重新兑换。过期未提交报价可重新填写。旧绑定30天、version、幂等、address_only/MFA逻辑保持，恢复与取消仍由服务端状态决定。
- 充值仍显示USDT/TRC20申请与收款信息，保留既有 WalletConversionCard 和 conversion_enabled 门槛，没有伪称充值自动变成点钻。

## 静态证据

PowerShell7 / Windows，Dart 3.12.2 windows_x64。

1. `dart format --language-version=3.4 wallet_page.dart manual_wallet_page.dart`：退出0，最终两文件无需进一步格式修改。
2. `dart analyze apps/mobile_flutter/lib/features/wallet/wallet_page.dart apps/mobile_flutter/lib/features/wallet/manual_wallet_page.dart`：最终退出0，No issues found。第一次报告4条花括号info和1条async context info，已修正并重新分析。
3. 本分工 `git diff --check`：退出0。

未运行单元/功能/真机测试、资金操作或APK构建；安装与后端上线证据由root另记，不能从静态分析推断真实提现已通过。

## 待用户验收

未绑定/绑定同步中/配置失败时灰色按钮无导航；改绑30天与版本冲突；独立页面返回；全部提现小数精度与多端余额变化；PIN未设、错误、取消、会话替换；报价过期、响应丢失、原订单重放；CAIBI取消退回来源与USDT旧单兼容；已有申请在功能关闭时恢复/取消；充值后兑换入口。

## 输入身份
- wallet_page.dart: 8A993358B18B928A71AA6A9FF5C48BC159097BEEF3160BBF93A42F89F4CEBA96
- manual_wallet_page.dart: 3265BBF17125E634A5C596CA365B46A8B7F97856DB3395B31E777F5E357C5F42
- pubspec.lock: 7B9D31B1CB4F394EDF5C2DA54778F00933D79591DF87E8C4ADDEA783D5A2A2B7

