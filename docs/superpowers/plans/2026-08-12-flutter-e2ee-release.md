# Flutter E2EE 与发布阶段实施计划

1. 增加 Matrix SAS 验证与跨签名服务，先写 Dart 单测，再实现 SDK 适配。
2. 增加加密备份安全中心 UI 与恢复流程测试。
3. 增加图片/文件/语音选择器、媒体加密发送服务和测试替身。
4. 将彩币、红包、钱包页面接入业务 API，覆盖加载、成功、失败和幂等请求。
5. 增加 Android Release 签名模板、构建脚本和无密钥验证。
6. 增加 GitHub Actions macOS TestFlight 工作流和发布 runbook。
7. 执行 analyze、test、APK 构建、Python 全量验证并提交。
