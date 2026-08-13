# 第二阶段 Flutter 功能验证

- Matrix 登录后进入消息页，执行 `Client.sync()`，显示真实房间列表并支持下拉刷新。
- 增加 SAS 验证操作页：接受、SAS 协商、确认匹配、拒绝。
- 增加加密备份创建/恢复 UI；恢复密钥仅传入 Matrix SDK。
- 增加图片、文件、语音消息入口，媒体通过 `MediaMessageService` 加密后发送。
- 彩币转账、红包创建、USDT 充值地址和提现申请页面接入业务 API，均沿用幂等键。
- Cupertino 动效保留 reduced-motion，主题根据系统亮暗模式动态切换。
- Android 品牌启动图已更新；Release APK/AAB 使用现有外部 keystore 构建。

验证：`flutter analyze`（仅 1 条异步 BuildContext lint 信息）、`flutter test`（2 passed）、Release APK/AAB 构建通过。
