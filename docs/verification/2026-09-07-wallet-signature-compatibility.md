# 私人 TRON 钱包消息签名兼容性核对

本记录是官方资料核对与本机只读清点，不是实机签名通过证据。官方 imToken 人工付款与用户私人钱包绑定签名是两个不同操作。

2026-09-07：MI 6 经 ADB 连接正常，按 token/tron 包名筛选未返回安装包；因此尚不能在该机验收 imToken/TronLink。已询问用户验收所用钱包及设备，不索取私钥或助记词。

用户随后强调官方充值地址唯一且固定。继续保留服务端官方地址配置及订单快照，用户不能修改。第三方钱包安装检查仅涉及私人地址控制权签名，不应作为 MI 6 测试平台 App 的前提；无需要求该机安装第三方钱包才能继续软件验证。私人绑定真实签名尚未完成，不能因官方地址固定而省略用户来源控制权核验。

## 官方来源与实现约束

- [TronWeb 6.1.0–6.1.1 signMessageV2](https://tronweb.network/docu/docs/6.1.0/API%20List/trx/signMessageV2) 明确字符串按 UTF-8 编码，`0x1234` 字符串不会被当作二进制哈希。当前后端验证的是原始挑战文本，不能在前端自行改成 hex 字符串后声称签名等价。
- [TronLink Message Signature](https://docs.tronlink.org/dapp/message-signing/) 列出 `window.tron.tronWeb.trx.signMessageV2`，但描述输入为 hex 字符串。它与上述 TronWeb 的文本说明不能直接合并推导钱包版本兼容；需固定钱包版本，签署同一个服务端挑战并由实际验证器恢复地址，覆盖中文/换行、拒签、换账户和过期。
- [TRON DApp integration](https://developers.tron.network/docs/tronlink-integration) 与 [TronWallet Adapter](https://developers.tron.network/docs/tronwallet-adapter) 提供注入式钱包和统一适配路径。它们是候选传输方案，不是已集成或所有钱包可用的证据。
- [imToken 消息签名说明](https://www.token.im/hc/en/articles/59725469008793) 的钱包内消息签名操作说明覆盖 ETH/BTC；[2.21.0 发布说明](https://token.im/blog/en-us/articles/59768306664217-imToken-2-21-0-Support-for-BTC-ETH-Message-Signing-and-Clearer-On-Chain-Interactions) 另说明 Tron TIP-712 支持。这些资料不能证明当前挑战所需的 Tron signMessageV2 在目标手机可用，也不能把 TIP-712 签名替代既有验证协议。

后续集成只使用钱包提供方的消息签名确认，不传入私钥、不签交易、不广播、不通过链上小额转账替代控制权证明。未经版本和真机核对的能力不显示为已支持；签名被拒绝或无法验证时保留未绑定状态。
