# 2026-08-24 公网登录部署验证

## 根因

此前安装的 APK 未传入 `LIUHETONG_BUSINESS_API_URL` 和 `LIUHETONG_MATRIX_HOMESERVER`，因此编译时使用 `apps/mobile_flutter/lib/core/app_config.dart` 的默认值：

```text
Business API: http://127.0.0.1:8082
Matrix:       http://127.0.0.1:8008
```

在 Android 模拟器中，`127.0.0.1` 指向模拟器自身，未运行本地服务，所以网络异常被登录控制器显示为“服务暂时不可用，请稍后重试”。

## 公网基线

命令：

```powershell
Invoke-WebRequest https://liuhetong888.com/api/v1/health/live -UseBasicParsing
Invoke-WebRequest https://liuhetong888.com/api/v1/health/ready -UseBasicParsing
Invoke-WebRequest https://liuhetong888.com/_matrix/client/versions -UseBasicParsing
Invoke-WebRequest https://liuhetong888.com/.well-known/matrix/client -UseBasicParsing
```

结果：四个请求均返回 HTTP `200`；Business API 返回 `ok:true`，Matrix well-known 返回 `https://liuhetong888.com/`。

模拟器网络检查：

```text
adb -s emulator-5554 shell ping -c 1 -W 3 liuhetong888.com -> 0% packet loss
adb -s emulator-5556 shell ping -c 1 -W 3 liuhetong888.com -> 0% packet loss
```

## MODIFIED

命令：

```powershell
pwsh.exe -NoProfile -File scripts/build_mobile_public_domain.ps1 -BaseUrl https://liuhetong888.com -BuildMode Debug
adb -s emulator-5554 install --no-streaming apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5556 install --no-streaming apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1
adb -s emulator-5556 shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1
```

结果：构建成功，`PUBLIC_ORIGIN=https://liuhetong888.com`；APK SHA-256 为 `B35C13AB4737FA8B924A502C561CAC1CDA040451CD2E871834E853EB68D43AD8`，大小 `242520888` bytes。两台设备均安装成功并启动：

```text
emulator-5554: versionName=0.1.0, process=4449
emulator-5556: versionName=0.1.0, process=10435
```

解包后的 APK endpoint 审计在 `assets/flutter_assets/kernel_blob.bin` 中发现 `https://liuhetong888.com`，未发现 `http://127.0.0.1:8082` 或 `http://127.0.0.1:8008`。

## 登录结论

当前两台模拟器连接的是公网服务器，不是本地服务器。登录页现在发往 `https://liuhetong888.com/api/v1/auth/login`；Matrix 登录/同步发往 `https://liuhetong888.com`。本次未使用真实账号凭据，因此只验证了 endpoint、TLS、服务健康状态、APK 编译参数和设备启动；使用有效账号密码即可继续验证业务登录结果。
