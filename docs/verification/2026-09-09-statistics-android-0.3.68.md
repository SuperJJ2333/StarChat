# 统计助手补发 Android 0.3.68 / 2072

## 原因及修复

用户指定主目录 `apps/mobile_flutter/assets/html/statistics_tools_combined_v2.html` 的未提交更新没有进入此前的隔离发布工作树。已发布 2070 APK 内该 HTML 的 SHA256 为 `c51c0f846b612696cd50834ca849385298092cf12ffffd1dc64975d4723480a1`，与用户文件不同。Flutter 统计助手实际通过 `loadFlutterAsset` 加载该资源，因此旧包显示旧工具。

本次按用户授权将该 HTML 原字节同步至发布工作树，保留其中中文金额输入、自绘提示和确认、防重复点击、按压反馈等修改，未混入主目录其他未提交代码。版本递增至 `0.3.68+2072`，以便已安装 2070 的客户端检测到更新。

预发布候选 2071 在仓库检查中发现 `app_config.dart` 的版本默认值仍为 0.3.67/2070。正常启动会通过 PackageInfo 更新实际版本，但默认值同样必须遵守版本契约；已同步默认值并重建为 2072。2071 没有启用更新配置，也没有切换 latest。原失败证据保留，`test_app_build_contract.py` 修正后两项通过。

## 目标资源验证

- 指定源文件大小 71,375 字节，SHA256 `89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5`。
- 发布工作树、最终签名 APK 中 `assets/flutter_assets/assets/html/statistics_tools_combined_v2.html` 与指定源文件逐字节一致。
- 旧 HTML 的浏览器回归因“输入五十后变成空字符串”按预期失败；同步后通过。
- 最终 APK 提取出的 HTML 也通过 Chrome 无头浏览器真实页面测试：中文金额、快速重复点击不重复累计、扣除取消/确认、撤销、三次重新加载及状态恢复、深色主题、清空取消及二次确认，零页面脚本异常。
- Flutter 统计助手入口、注册与会话缓存隔离共 5 项测试通过。
- 生肖统计的加减、取消/确认、清空和扣除按钮恢复，以及总单重复号码合并回归通过。
- 本次未卸载或覆盖 Redmi 的不同签名 Debug 包；上述浏览器测试不冒充 Android WebView 真机覆盖安装验收。

## 正式构建

源码基线为此前正式版记录提交 `cea10bdf`，新增产品文件只包含目标 HTML、pubspec 版本及 app_config 版本默认值。使用 Flutter standard release、ARM64 和三个既有生产 HTTPS dart-define 构建，随后按 runbook 完成 Apktool 2.12.1 重建、16K 对齐及固定签名。

- APK：`ChatFlow-0.3.68-build2072-arm64.apk`，77,010,443 字节。
- APK SHA256：`0e68c73cd4531efc1c66283ca9261191adf3babd5c35250154c02bd2be347f16`。
- 固定证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。
- 包名 `com.liuhetong.mobile`，版本名/构建号校验通过，无 debuggable；源包及最终包通过发行 ABI 门禁。
- 重建前后 24,573 个类语义、337 个原生库/资产条目及 Manifest 语义一致，五个 DEX 和资源完成重建。

## 复核

规格复核先确认用户文件、工具加载路径、最终资产字节、新构建号及仅 Android 范围。随后质量/安全复核确认页面脚本回归通过、会话桥协议保留、没有新增服务器通信或财务状态变更、固定签名连续、发行脚本仍使用一次审计事务。当前源文件的统计计算为既有设备端工具行为，没有改动业务账本。

原始证据位于 `docs/verification/artifacts/2026-09-09/redmi-polish/`：`statistics-red.log`、`statistics-green.log`、`statistics-flutter-test.log`、`statistics-apk-2072-smoke.log`、`statistics-asset-before.json`、`statistics-final-2072.json`、`package-release-2072/`、`source-release-2072.log` 和 `rebuild-release-2072.log`。APK、测试输入和临时环境文件不进入 Git。

## 发布状态

已发布 [Android 0.3.68 / 2072](https://www.liuhetong888.com/downloads/ChatFlow-0.3.68-build2072-arm64.apk)。发布前本地最终包、服务器暂存包、服务器默认公网完整下载及本机公网完整下载哈希一致；发布后的 latest 完整下载也一致。

本机默认 DNS 解析到代理地址 `198.18.0.11`，默认路径出现 TLS 握手失败；本机下载改用 `--noproxy '*' --resolve www.liuhetong888.com:443:207.56.8.8`，仍严格校验原 HTTPS 域名证书，没有关闭 TLS 校验或修改系统网络设置。服务器默认 DNS 公网路径正常。

`scripts/verify.ps1` 最终执行返回 `Verification: PASS`，记录为 `statistics-repository-2072.log`。包括客户端边界 66 项、业务 API/Worker 362 项通过及 19 项现有环境条件跳过；另有既有依赖弃用警告，未屏蔽。初次验证缺少本地 `.env`，使用 `.env.example` 的合成测试配置在证据目录建立临时配置及链接后执行，结束移除了工作树 `.env` 链接，没有读取生产密钥或部署迁移。

通过线上应用服务一次 `set_many` 更新五项发布配置，actor 为 `ops-codex-android-release`，trace 为 `android-release-0.3.68-2072-20260909`，五条审计记录及客户端路由的进程内投影读回一致。该投影验证不冒充登录客户端 HTTP 验证。最低支持构建号仍为 3；原子切换 `latest-arm64.apk` 至 2072，保留 2070 APK。业务 readiness 返回数据库 ready。此次发布应用更新检查配置，没有发送逐用户消息通知，也没有发布 iOS、IPA 或 TestFlight。

发布证据为 `release-2072-preflight.log`、`release-2072-publish.log`、`release-2072-latest.log`、`release-2072-postflight.log`、`public-hash-2072.log`。原配置本地备份为 `release-2072-before-settings.json`；服务器持久备份及脚本位于 `/opt/starchat/docs/verification/artifacts/2026-09-09/android-release-2072/`。如需回退，先确认没有后续发布，按该目录脚本的受保护 `rollback` 模式恢复原五项配置，再原子恢复 2070 latest 并验证。回退未执行。
