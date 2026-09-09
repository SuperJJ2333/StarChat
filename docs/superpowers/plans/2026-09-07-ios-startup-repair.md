# iOS 首次启动白屏修复细化

依据：用户已授权完成可运行的 iOS 包，并报告首次启动持续白屏。沿用 2026-09-07-ios-apns-build.md 与既有 Flutter 发布计划。本次仅修复启动和构建集成，不更改加密算法、数据库格式、密钥或会话策略。

文件归属：ios/Runner.xcodeproj/project.pbxproj、独立启动诊断与签名工作流、构建验证脚本、此计划及验证证据。保留工作区其他任务改动。

1. 原始 IPA 的 Mach-O 加载顺序检查已失败：系统 SQLite 排在 SQLCipher 之前；原始源码 iPad 模拟器运行收集日志/画面，区分该配置风险与真实故障。
2. 按 sqlcipher_flutter_libs 0.6.8 上游 README，只对 Runner Debug/Profile/Release 的 OTHER_LDFLAGS 前置 -framework SQLCipher，继承其他参数。单一变更验证假设，不修改 Dart 数据库代码。
3. 模拟器连续因 Pods_Runner 编译失败后，改用 USB 真机采集。2026-09-07 19:19 的原版 0.3.47（6）日志已确认 SQLCipher 校验失败，异常沿 MatrixClientFactory.create 到 main，发生在 runApp 前。
4. 生成只含链接修复的签名候选包；上传前必须验证实际 IPA 中 SQLCipher framework 存在、加载顺序优先及原有签名/权限检查。模拟器当前不可用，通过 TestFlight 更新真实 iPad 才能验证 Release 启动；候选包上传不等于已修复。保留数据，升级后采集同一设备日志并确认登录入口出现。若仍失败，按新日志继续定位。
