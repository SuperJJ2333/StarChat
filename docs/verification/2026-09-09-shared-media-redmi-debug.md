# Redmi Debug 2075 安装交付

用户请求：推送本次 Debug 版本到 Redmi，供本人检验。

- 源码提交：`517ca879`；ARM64 standard 完整应用，入口 `lib/main.dart`，不是自动化测试 harness。
- 版本：`0.3.71-debug / 2075`；包名 `com.liuhetong.mobile`。
- 设备：Redmi `cbd0156b`。
- `adb install --no-streaming -r` 返回 **Success**。未使用卸载、清数据、降级或 flutter drive。
- 手机 PackageManager 确认 versionCode=2075、versionName=0.3.71-debug。
- 主 Activity 启动返回 `Status: ok`。
- 安装包、手机 Download 文件与已安装 base.apk SHA256 一致：`370eaec88ce195e4e0db439789d77aab4e185172174e01268e03c4369357117b`。
- 文件大小：142355282 字节。
- 手机文件：`/sdcard/Download/ChangLiao-0.3.71-debug-2075.apk`。
- 最终本地 APK：`docs/verification/artifacts/2026-09-09/shared-media-identity/redmi-2075/final.apk`。

## 固定重建流程

源码 Debug 构建保留三个 HTTPS dart-define（Business API、Matrix、Getui 指向 `https://liuhetong888.com`），通过构建参数递增版本。使用 Apktool 2.12.1 完整解包重建，build-tools 36.0.0 对齐和签名，再完整解包校验。

沿用该 Redmi 此前验证的 Debug 签名（既有 Debug 身份延续，不生成新密钥）：`34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`。

结果：26537 个 smali 类一致，338 个原生库/Flutter 资产条目哈希一致，清单语义一致；签名、16KB 对齐、唯一 ARM64 ABI 和真实 Debug kernel 校验通过。相关日志和机器可读 `verification.json` 均在同一产物目录。

## 检验边界

- 完成 APK 推送、安装和启动核验；具体交互留给用户检验，不将此记录当作全面功能或性能真机测试。
- 线上媒体接口只读检查仍返回 JPG/PNG/WebP，**本次 GIF 服务端改动尚未部署**。内置表情、备注/头像、共享相册界面可以检验，GIF 评论完整发送需同步服务端。
- 本次安装解决前一任务中“正常包不存在”的安装状态；没有证明先前卸载前的登录状态、本地缓存或加密密钥已经恢复。
- 没有发布 Android 正式更新或 iOS 更新。
