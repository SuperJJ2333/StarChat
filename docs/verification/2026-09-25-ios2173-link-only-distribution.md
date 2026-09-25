# iOS 2173 回签 IPA 与官网链接分发核查（2026-09-25）

用户要求只更新官网下载/安装链接，应用内弹窗保持关闭。结果：**门禁失败、未分发**。

## 回签包

- 文件：根工作区 `docs/verification/artifacts/2026-09-25/ios2173-candidate/ChatFlow-0.4.7-build2173.ipa`；SHA256 `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0`，61,495,036 字节。
- `verify_ios_enterprise_ipa.py` 退出码 0：Bundle `com.liuhetong.liuhetongMobile`，0.4.7/2173，Team `ZXB3TS7QD4`，profile 与 Runner 已签 App ID 同为 `ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext`，Keychain 组 `[ZXB3TS7QD4.*, com.apple.token]`，生产 APNs，企业分发，`get-task-allow=false`。企业证书 SHA256 `26c4398b38d79a389509237d02fee6133755c4c3d786179aa4c43f3142b46b22` 与归档 2144 相同。
- `compare_ios_ipa_payload.py` 对 CI 原包 SHA256 `d05e4ea1178121fa37d5db7a85e2d0e901b1ae57ea5fb9eb5df64544488b63c1` 退出码 **1**，`status=fail`。新增 `AppRuntime/ATHelper.dylib`、`Partner/libutils.dylib`、`flag`，Runner arm64 Mach-O 加载命令变化；Runner 含两个动态库名，不只是 ZIP 附加文件。
- 报告位于根工作区 `docs/verification/artifacts/2026-09-25/ios2173-distribution/final-ipa-validation.json` 和 `payload-comparison.json`。本次未执行动态库。

## 生产和设备

- 2026-09-25 08:19 +08 生产只读快照：iOS API 设置 0.3.102/2144、最低 build 3、下载 URL `https://www.liuhetong888.com/download?platform=ios&install=1`。官网 manifest、下载页与首页 JS 均为 2144；服务器无 2173；Android 为 0.4.7/2172。
- 线上 SHA256：`download.html` `adb300047adc69d99659bbb1e712c1feb4310bab8fd96abd5b9aca39307250c0`；`src/admin-home.js` `3d2c91d80169ae4478e0e80afee1322ff3afaf7dd08cef92390f13b948df3efd`；`downloads/ios/manifest.plist` `a7b89bf847cdfe413c9ad2cb50eab3ffa897d5c363e472aa92cab5c2bfc4de6f`。
- Windows USB 检出 iPhone 8/iOS 16.7.16，但无健康 2144 持旧数据基线；未安装或改动设备。因此不能宣称此包已覆盖升级保留旧数据。
- 自动更新与“设置 → 关于畅聊 → 版本更新”共用 `/app-updates/latest?platform=ios`。提升 `app_ios_latest_version/build` 会使旧客户端弹窗；用户选择官网链接方案，后续发布须保持五项 `app_ios_*` 不变，应用内手动检查仍显示原版本。

## 结论

签名服务改动了应用可执行代码，违反最终 IPA 与 CI 原包仅签名差异的门禁。**无生产写入、无官网链接切换**。签名方关闭注入/加固，从原始 CI IPA 纯回签；新包到达后重新验证，并在健康旧版 iPhone 上验证不卸载覆盖保留数据。
