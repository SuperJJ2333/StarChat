# 六合通 Phase 7 Flutter / Matrix E2EE 实施计划

## 边界
Flutter 负责 Android/iOS 统一客户端、会话安全存储和 Matrix 客户端加解密。业务 API 只负责身份、彩币、红包、钱包事实；Matrix/Synapse 只传输密文事件和密文媒体。

## 首版交付
- 用户名/邮箱/邀请码注册与会话刷新
- Matrix 同步、设备验证、跨签名和加密备份接口
- 加密文本、文件、图片、语音消息 UI 接口
- 彩币转账、红包、USDT 钱包 API 客户端
- 通用推送只携带 opaque room/event 标识，不携带正文

## 当前环境限制
本机未安装 Flutter SDK，首阶段提交可静态审查的 Flutter 工程骨架；在 CI/TestFlight 构建机执行 Flutter 构建与集成测试。
