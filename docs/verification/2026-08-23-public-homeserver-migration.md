# 2026-08-23 公网服务地址迁移验证

- 代码基线：`80bd6c6` 加本次 Matrix Homeserver 迁移修改。
- 目标：不清除加密本地数据库、会话或恢复密钥的前提下，将旧 APK 持久化的 Matrix Homeserver 从本机地址改为公网 HTTPS 地址。

## 实现

`MatrixClientFactory` 在持久化 Matrix Client 初始化后，保留原有 SQLCipher 数据库和 Olm 状态，仅更新 SDK 内存和数据库 `homeserver_url` 为当前编译配置；不调用 `logout`、`reset`、数据库删除或密钥轮换。

## BASELINE

命令：

```text
adb -s emulator-5554 logcat -d
```

结果：

```text
ClientException with SocketException: Connection refused, uri=http://127.0.0.1:8082/api/v1/profile/me
[Matrix] Syncloop failed: Client has not connection to the server
```

退出状态：`0`。

## MODIFIED

命令：

```text
C:\src\flutter\bin\flutter.bat build apk --debug --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com
adb -s emulator-5554 install -r apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 shell monkey -p com.liuhetong.mobile -c android.intent.category.LAUNCHER 1
```

结果：

```text
Success
[Matrix] Successfully connected as a1014826460 with https://liuhetong888.com
离线提示节点计数：0
```

退出状态：`0`。

## ROLLBACK

命令：

```text
adb -s emulator-5554 install -r <previous-apk>
```

结果：恢复旧 APK 行为；应用数据和本地 E2EE 数据未被清除。服务器源代码回滚点为部署前归档：`/opt/starchat-backups/starchat-before-.tar.gz`。

退出状态：未执行（当前 APK 保持已修复状态）。

## 证据

- 初始 UI：`docs/verification/artifacts/2026-08-23/emulator-window.xml`
- 修复后 UI：`docs/verification/artifacts/2026-08-23/emulator-window-after-homeserver-migration.xml`
- 源码同步清单：`docs/verification/artifacts/2026-08-23/deploy-file-list.txt`
