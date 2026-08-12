# 六合通 Flutter E2EE 与发布阶段设计规格

**状态：已批准**  
**日期：2026-08-12**  
**范围：** Matrix SAS/跨签名/加密备份、加密媒体、业务 API 客户端、Android Release、GitHub Actions macOS TestFlight。

## 架构边界

Matrix/Synapse 只承载密文事件、设备和房间同步。Flutter 端负责 SAS、跨签名、SSSS、媒体本地加密和解密。业务 API 负责彩币、红包、钱包的权威状态；客户端不根据 Matrix 卡片或 UI 状态修改资产。

恢复密钥、房间密钥、设备私钥、明文媒体不得发送给业务 API，不得写入日志。金额使用字符串传输，不使用二进制浮点计算。

## Matrix 安全流程

`MatrixVerificationService` 管理 KeyVerification 生命周期：发起/接受请求、展示 SAS、用户确认、完成验证并持久化验证状态。Cross-Signing 初始化创建 Master/Self-Signing/User-Signing 密钥，使用 SSSS 加密存储，并在已验证设备间共享。恢复流程支持恢复密钥和密码，失败可重试但不泄露密钥。

## 媒体消息

图片、文件和语音先在设备本地加密，再以 Matrix 加密媒体事件发送。选择器限制大小和 MIME，录音生成语音文件，上传提供进度、取消和重试。服务端仅接收密文媒体。

## 业务页面

彩币页调用余额和转账 API，明确 0.5% 手续费；红包页调用创建、领取、状态 API，支持普通/拼手气、群聊/私聊和 24 小时过期；钱包页调用 USDT-TRC20 充值、提现、查询和未知结果刷新 API。每个写请求使用唯一幂等键。

## 发布

Android Release 使用环境变量注入签名配置，仓库只提交示例文件。GitHub Actions macOS runner 执行 Flutter/Xcode 构建并使用受保护的 Apple 签名与 App Store Connect Secret 上传 TestFlight。Windows 不执行 iOS 构建。

## 验收

- Dart analyze/test 通过；Matrix 流程有单元测试。
- Android debug/release 构建通过（无真实密钥提交）。
- 业务 API 页面请求和错误状态有 widget 测试。
- CI 工作流 YAML 可解析，Secret 名称和脚本有文档。
- 完整 `scripts/verify.ps1` 通过。
