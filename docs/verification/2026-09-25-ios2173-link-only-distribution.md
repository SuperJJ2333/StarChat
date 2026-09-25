# iOS 2173 回签 IPA 与官网链接分发核查（2026-09-25）

用户要求只更新官网下载/安装链接，应用内不弹更新提示。最初纯回签门禁失败；用户随后明确接受此企业签方式并要求直接发布。**官网 0.4.7/2173 已分发，应用内 iOS 更新检查仍是 2144。**

## 回签包

- 文件：根工作区 `docs/verification/artifacts/2026-09-25/ios2173-candidate/ChatFlow-0.4.7-build2173.ipa`；SHA256 `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0`，61,495,036 字节。
- `verify_ios_enterprise_ipa.py` 退出码 0：Bundle `com.liuhetong.liuhetongMobile`，0.4.7/2173，Team `ZXB3TS7QD4`，profile 与 Runner 已签 App ID 同为 `ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext`，Keychain 组 `[ZXB3TS7QD4.*, com.apple.token]`，生产 APNs，企业分发，`get-task-allow=false`。企业证书 SHA256 `26c4398b38d79a389509237d02fee6133755c4c3d786179aa4c43f3142b46b22` 与归档 2144 相同。
- `compare_ios_ipa_payload.py` 对 CI 原包 SHA256 `d05e4ea1178121fa37d5db7a85e2d0e901b1ae57ea5fb9eb5df64544488b63c1` 退出码 **1**，`status=fail`。新增 `AppRuntime/ATHelper.dylib`、`Partner/libutils.dylib`、`flag`，Runner arm64 Mach-O 加载命令变化；Runner 含两个动态库名，不只是 ZIP 附加文件。归档 2144 等企业包也有同名同大小库、`flag` 和两条加载命令；2173 Runner 除两条加载命令与签名外，主程序代码与 CI 原包相同。没有证明注入库本身的代码字节或运行行为相同。
- 报告位于根工作区 `docs/verification/artifacts/2026-09-25/ios2173-distribution/final-ipa-validation.json` 和 `payload-comparison.json`。本次未执行动态库。

## 生产和设备

- 2026-09-25 08:19 +08 生产只读快照：iOS API 设置 0.3.102/2144、最低 build 3、下载 URL `https://www.liuhetong888.com/download?platform=ios&install=1`。官网 manifest、下载页与首页 JS 均为 2144；服务器无 2173；Android 为 0.4.7/2172。
- 线上 SHA256：`download.html` `adb300047adc69d99659bbb1e712c1feb4310bab8fd96abd5b9aca39307250c0`；`src/admin-home.js` `3d2c91d80169ae4478e0e80afee1322ff3afaf7dd08cef92390f13b948df3efd`；`downloads/ios/manifest.plist` `a7b89bf847cdfe413c9ad2cb50eab3ffa897d5c363e472aa92cab5c2bfc4de6f`。
- Windows USB 检出 iPhone 8/iOS 16.7.16，但无健康 2144 持旧数据基线；未安装或改动设备。因此不能宣称此包已覆盖升级保留旧数据。
- 自动更新与“设置 → 关于畅聊 → 版本更新”共用 `/app-updates/latest?platform=ios`。提升 `app_ios_latest_version/build` 会使旧客户端弹窗；用户选择官网链接方案，本次保持五项 `app_ios_*` 不变，应用内手动检查仍显示原版本。

## 发布与回读

- 独立发布器 `scripts/publish_ios_static_links.py` SHA256 `380bdfb8e1b42d2dc15151ce4356ae423f8c83d4f49ca32efa42aaefd80b0579`，发行相关 Python 92 项通过；`py -3.12 -m pytest tests/mobile -q --tb=short` 232 通过、1 跳过、退出码 0；前端两个下载入口测试 6/6 通过；独立规格与质量审查无阻断。发行记录锁定 CI/final IPA SHA、四项已知注入差异、三个线上静态文件 SHA 和 Android+iOS 10 项设置完整前态；旧值漂移则拒绝写入。用户的明确例外只适用于这份 SHA，不改原纯回签发布门禁。
- 最初执行因发行记录的 `payload_exception.final_sha256` 少抄 5 位而在备份/静态写入前退出 1；确认旧三文件、目标 IPA 和备份仍不存在/未变后，修正记录并重试。第二次 `STATIC_IOS_LINKS_PUBLISH_PASS`，服务器 0700 备份：`/opt/starchat/docs/verification/artifacts/2026-09-25/ios2173-link-only-release/backup-20260925T0842HKT`。
- 服务器不可变 IPA 61,495,036 字节、SHA256 `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0`。服务器 `release_metadata.py check` 得 `METADATA_CHECK_PASS`；公网 HEAD 200，Content-Length 相同；服务器与工作站经 jump SOCKS 下载的 `download.html`、`admin-home.js`、`manifest.plist` 哈希分别 `583fb07b9bb21a0b2ab1b95b0357e72f91d4359ae7d8ca42b4a455007822bb42`、`8f55e6254b704d55d32c5c65ac75cfe52818117f2ca672f77c7759ac88a81e01`、`430f5f0bac4c9d8d80d8ff1e35852745d3dc2a62cedf6e7de8bcded5f5df64eb`。manifest 为 Bundle `com.liuhetong.liuhetongMobile`、build 2173，指向新 IPA。临时隧道已关闭。
- `app_ios_latest_version/build` 仍 `0.3.102/2144`，iOS 安装页 URL、最低支持 build 和说明不变；Android 5 项也不变。网页发布没有数据库设置写入，未启用 2173 应用内更新弹窗；应用内手动检查仍返回 2144。
- 工具与输入：Windows PowerShell 7.6.5、Python 3.12.10、Node 22.22.2；服务器 Python 3.12.3/OpenSSL 3.0.13。发行 JSON SHA256 `c4d9f589a8e87fec61125712c8589e946e915d5313929f40337aa83a868b65b9`，CI run 36044338640。未改变 Flutter/后端依赖锁、业务 API、数据库或 Android 包；本次按移动交付变更影响规则重跑发行、移动与前端入口门禁，不重复此前已完成且输入未变的后端长门禁。

## 结论

官网安装入口：[iOS 下载页](https://www.liuhetong888.com/download?platform=ios)；[不可变 IPA](https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.7-build2173.ipa)。企业签名注入是用户明确授权的本次例外，静态校验不能证明注入库运行安全。健康 2144 iPhone 的**不卸载覆盖、旧数据与登录保留**和后台通知/来电仍待真机反馈；本次未安装设备，不得宣称通过。
