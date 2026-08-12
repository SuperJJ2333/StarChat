# 2026-08-12 本地移动端发布与 Matrix 环境验证

## 本地环境

- Matrix homeserver: `http://localhost:8008`（Android Emulator 使用 `http://10.0.2.2:8008`）
- Business API: `http://localhost:8082`（Android Emulator 使用 `http://10.0.2.2:8082`）
- Synapse: Docker healthy
- Business API: Docker healthy

## 验证结果

- Matrix `/_matrix/client/versions`: HTTP 200
- Matrix 测试账号登录：通过
- Matrix `/sync`: 通过，返回 next_batch
- `flutter analyze`: 通过
- `flutter test`: 通过
- Android signed release APK: 通过
- Android signed release AAB: 通过
- APK v2 signature verification: 通过
- Business API health: 通过

## 需要 macOS/真实账号的验证

iOS Simulator 构建需要 macOS。SAS UI 交互、SSSS 恢复、加密媒体发送需要在 Flutter 运行时使用测试设备验证；本机已完成 SDK 编译和 Matrix HTTP 登录/同步基础验证。
