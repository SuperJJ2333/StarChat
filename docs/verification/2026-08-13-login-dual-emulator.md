# 2026-08-13 登录页面与双雷电模拟器测试

## 变更

- 新增 Flutter 登录页面，用户名/密码输入、加载态、错误态、空值校验。
- 业务 API 登录成功后保存 access/refresh token。
- 登录回调随后初始化 Matrix homeserver、Matrix 登录并执行首次同步。
- 默认地址支持 Android Emulator：`10.0.2.2:8008` / `10.0.2.2:8082`。

## 设备测试

- `emulator-5554`：debug APK 安装、启动、登录页显示、空表单校验通过。
- `emulator-5556`：卸载旧签名版本后安装 debug APK、启动、登录页显示、空表单校验通过。
- Flutter `flutter run -d emulator-5554 --debug --dart-define=...` 已启动应用；命令因常驻调试会话超时退出，设备侧 MainActivity 已显示，未发现 FATAL EXCEPTION。
- `flutter analyze`：通过。
- `flutter test`：2 个测试通过。
- `flutter build apk --debug --no-pub`：通过。

## 未完成运行时场景

真实业务登录、Matrix SAS 双设备确认、SSSS 恢复、加密媒体和资产接口仍需要有效业务账户、两个 Matrix 设备和测试房间；当前只完成了登录页和基础启动/输入验证。
