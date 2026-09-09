# MI 6 当前源码 debug 包

用户要求 debug 包和 debug 签名。本次不使用正式发行证书。

- 最终包：`artifacts/2026-09-07/wallet-debug-mi6/ChatFlow-0.3.53-arm64-debug-rebuilt.apk`。
- 包名 `com.liuhetong.mobile`，versionName `0.3.53-debug`，versionCode `2055`，ARM64，debuggable。
- 使用现存 Android Debug 身份；与设备旧包证书一致，SHA256 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`。未生成新密钥。
- APK SHA256 `c6868045dbe305df01ae77f28e46b9cc826f3676724c60be7c0ffa8ecb0212a7`。
- Flutter 源码 debug standard 构建；Business API、Matrix、Getui 三项 define 均为 `https://liuhetong888.com`；显式版本覆盖，不改 pubspec。
- Apktool2.12.1 重建、build-tools36.0.0 zipalign 16KB 对齐后签名；签名验证、签后对齐、aapt 身份检查通过。重解包验证24912个类一致，332项lib/assets字节一致，完整清单语义一致。源码包验证只含arm64-v8a，保留debug kernel与Flutter引擎。
- 覆盖安装 `adb install -r` 返回 `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`。未卸载、清除数据、绕过限制或重试；旧0.3.52-debug/2054仍在设备中。未完成新包启动验收，需要用户允许手机端安装后继续。

构建与安装日志、签名/清单以及 verification.json 位于上述 artifact 目录。该包仅包含当前源码，不代表尚未接线的资金页面或真实生产充提已启用；未推送正式更新弹窗。

## 用户授权重试后的结果

用户回复“重试”后，再次执行同一最终包的 `adb install -r`，返回 Success。设备确认版本0.3.53-debug/2055、DEBUGGABLE；设备已安装APK的SHA256与上述最终包完全一致。MainActivity启动返回Status: ok，并取得应用运行进程。未卸载或清除数据。证据：`install-retry.txt`、`launch-retry.txt`、`device-installed.txt`。此为安装和启动检查，不代表全部业务功能验收。
