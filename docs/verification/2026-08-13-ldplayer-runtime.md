# 2026-08-13 雷电模拟器运行测试

## 设备

- ADB serial: `emulator-5556`
- Package: `com.liuhetong.mobile`
- Version: `0.1.0 (1)`
- Target SDK: 36

## 通过项

- ADB 设备连接：通过
- Release APK 安装：通过
- MainActivity 启动：通过
- Flutter 进程无 FATAL EXCEPTION：通过
- UIAutomator 找到“六合通”：通过
- 彩币 Tab：通过
- 红包 Tab：通过
- 钱包 Tab：通过
- 返回彩币 Tab：通过
- Matrix homeserver HTTP 登录和 `/sync`：已在主机验证通过
- 本地 Synapse 和 Business API Docker：healthy

## 当前运行时限制

应用当前使用默认 `10.0.2.2` 地址，且未在客户端注入业务登录 Token，因此余额卡片显示“余额暂不可用”是预期的未认证状态。SAS、SSSS 恢复和加密媒体需要在应用内登录后由两个 Matrix 设备参与，不能仅通过无账号的启动测试完成。

真机/模拟器环境变量示例：

```powershell
flutter run -d emulator-5556 `
  --dart-define=LIUHETONG_MATRIX_HOMESERVER=http://10.0.2.2:8008 `
  --dart-define=LIUHETONG_BUSINESS_API_URL=http://10.0.2.2:8082
```
