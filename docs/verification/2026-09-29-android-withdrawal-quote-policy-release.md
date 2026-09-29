# Android 0.4.24+2193 提现报价兼容修复：构建与正式发布核验

## 范围与结论

- 用户批准从 Android Debug 0.4.23+2192 冻结源码修复 `Invalid manual wallet response`，先交付模拟器 Debug，再发布正式 ARM64。客户端只把 `SUPPORT_MANUAL_V1` 加入已有报价策略解析，继续接受 `OWNER_MANUAL_V1`，未知值拒绝；服务端、iOS、资金确认、操作验证与幂等逻辑不变。批准的[规格](../superpowers/specs/2026-09-29-android-withdrawal-quote-policy-compatibility-design.md)和[实施计划](../superpowers/plans/2026-09-29-android-withdrawal-quote-policy-compatibility.md)界定范围。
- 2026-09-29 21:27–21:39 +08:00，正式 Android ARM64 `0.4.24+2193` 完成香港直链、SG CDN、标准设置及网络择优设置两阶段发布；最终网络择优入口已回读。iOS 保持 `0.4.20+2189`，Business API 保持既有 v4r2 镜像/schema 0092。**真实账户报价和正式包真机体验尚未验收**；匿名 401 只证明受保护路由未开放给匿名访问，没有执行资金操作。

## 源码、测试和包身份

| 项目 | 实测/证据 |
| --- | --- |
| 冻结源码 | `dae8ec6301e4c22d09721c6f54ccc9cc90bc6f3d`；ARM64 构建树的 1811 个移动路径与 Debug 冻结清单逐字节一致；正式 source/generated 清单 SHA256 `bf3c85366adc5f468fcfdc8dfdf6787115169409daa97ed320d48f1479003f73`，`pubspec.lock` SHA256 `314504b9bf3917b30a6e12b3262eca23f774a43e4b23a88a801ae35bbea76bf3`。见 [Task 5 原始构建报告](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/release/task5-report.md)。 |
| Debug 模拟器 | x86_64 Debug `0.4.24+2193` SHA256 `167b70ab76a554c1bf7df645008926ec7ccf9d3fda690c3b9b92ba21f8cb2372`，`adb install -r --no-streaming` 到 `emulator-5556`，原 firstInstallTime 和数据保留，装机包 SHA 相同。见 [Task 4 证据](artifacts/2026-09-29/withdrawal-quote-2193/android-debug/task4-summary.md)。 |
| ARM64 正式包 | [最终 `final.apk`](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/release/run-20260929-205721-2193/final.apk)，81,767,454 字节，SHA256 `8ea9eafb95bcf07c5655266d3eb71766c5799ba364103b23004820f3cf4e6dec`；`com.liuhetong.mobile`、版本 `0.4.24`/build `2193`、非 debuggable、仅 `arm64-v8a`，固定证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。 |
| 构建门禁 | Apktool 2.12.1 常规 DEX/资源/manifest 重建、zipalign、固定签名；源/最终包 25,346 类语义、原生库/Flutter 资产及 manifest 一致。aapt/apksigner、ABI 和 release payload 检查通过。首轮 Flutter release 构建因生成的 dev-only `integration_test` 注册项 exit 1，限定范围修正该生成块后重试 exit 0；[步骤退出码](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/release/run-20260929-205721-2193/steps.tsv)保留首轮失败。独立规格与质量/安全复核 PASS，无 P0–P2。 |
| 源码测试 | 报价解析 RED/GREEN、钱包回归 38/38、Flutter analyze exit 0；短盘符全量 Flutter 5132 通过/9 跳过、exit 0；移动边界 238 通过/1 跳过。原长路径全量因 Windows 265 字符临时路径 exit 1 后已短路径复验；整库 `scripts/verify.ps1` 因独立工作树缺 `.env` exit 1，不能列作通过。见[任务记录](../workflow/tasks/2026-09-29-android-withdrawal-quote-policy.md)。 |

Task 5 准备、构建及独立回读约 20:38–21:06 +08:00，精确起止秒未记录；该区间与 Task 3/4 并行，不能简单相加为人工耗时。原始 [artifact.json](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/release/run-20260929-205721-2193/artifact.json)和[语义核验](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/release/run-20260929-205721-2193/rebuild-verification.json)保留完整身份和退出结果。

## 生产门禁与两阶段发布

1. 写入前只读核对：现网 API v4r2 完整 digest `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd`、healthy/restart 0、schema 0092、受保护匿名 401；Android `0.4.21+2190`、iOS `0.4.20+2189`。HK/SG 私有暂存包的 SHA/大小均与上述最终签名包相同。
2. SG 私有 0600 快照保存原 S3 policy SHA256 `f33c073094ac781768121ba46d5f3fb1c13b1b30c76715019ed6d609aa905603`、原 CloudFront config SHA256 `2a094f101a0cd1933cd6ae9c110d443851cafce3989e6afec24f38a203d843d7` 及 ETag。CloudFront 以 ETag CAS 增加 2193 精确路径行为，保留 2188/2190 旧行为；最终 ETag `E3UN6WX5RRO2AG`、Status `Deployed`。CDN 发布器在写 S3 前确认第三行为已部署；S3 policy 精确保留旧两对象并加入第三对象，对新对象的 checksum、大小、metadata、AES256、不可变缓存进行回读。HK `latest-arm64.apk` alias 由 2190 原目标原子切换到 2193；旧精确链接保留。
3. 标准阶段发布 Android version/build/直链三项设置，各产生一次审计并回读；随后网络阶段在同一 2193 version/build 下仅更新 `app_apk_url` 为网络择优入口，另产生一次审计并回读。两阶段备份目录分别为 `/opt/starchat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193-standard-20260929T132752Z` 与 `/opt/starchat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193-network-20260929T132929Z`，均为 0700，包含 before/after JSON 和审计。iOS 设置及 API 镜像未写入。两份[发布记录](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/release-standard.json)、[网络记录](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/release-network.json)使用最终包的真实 SHA/大小和三个在线 JS 资产 SHA。

发布脚本专项 4/4、Android 网络发布/设置专项 48/48 通过。扩大到旧 iOS 发布器测试后为 63/66：三项旧 iOS 用例的按钮正则未容纳现行 `aria-describedby` 标记。本次 Android 发布按实时下载页与首页静态输入生成两阶段差异，比较确认 iOS 区块字节不变；记录原测试失败，不将其当作本轮 Android 行为通过证据。

网络择优静态源码提交 `102f94b9fce0b358c1b1ffef58b6a09b6cd92e7c` 仅回填已发布的下载页、Android registry 和三段下载 JS，5/5 个 Git blob 与公网字节精确一致。公网管理台 `admin-home.js` SHA256 保持 `7d065a9ce3455a41f30a601ad8423929a9ee09c14a0933a672de109c1c71920e`；本 C 工作树继承的旧 `admin-home.js` 不是现网版本，**不能据此整站静态部署**，须在后续管理后台分支整合后 rebase 并重跑门禁。前端新增测试 RED 3/3→GREEN，下载/源码专项 53/53、完整 `npm test` 361/361、0 失败；source-contract 只保留 `download-network.js` 两处已批准的 URL 表达式例外。源码同步未触碰冻结移动源码及签名 APK。

## 公网与工作站回读

| 检查 | 结果及本地证据 |
| --- | --- |
| 业务 API | 严格 TLS [ready 200、database ready](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-ready.json)；[匿名提现报价 401 `AUTH_REQUIRED`](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-quote-anonymous.json)。 |
| Android 入口与静态 | 下载页 200；[公网 registry](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-android-release.json)为 2193、81,767,454 字节与最终包 SHA；三个公网 `download-redirect.js`、`download-network.js`、`download-network-selector.js` 的 SHA256 分别为 `a8f27e541081ae79c242dbccd075e780de7030cccf8c0d55c68dd5e7df5ac827`、`4699ca1c729138990d79b12303b30ec7b71335a97ebb2859bb914fd55bc0302a`、`a4030bc497d0453cc11f00a5bd4f567be8229a2ce822d93da738af211e6ab446`，与网络发布记录一致。 |
| Android 包分发 | HK alias/精确链接与 CDN 精确链接 HEAD 200、长度 81,767,454；[HK HEAD](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-hk-alias-head.txt)、[CDN Origin Range](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-cdn-2193-origin-head.txt)及[缓存 Range](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-cdn-2193-range-head.txt)为 206、CORS 与总长正确。2188/2190 旧链接仍可用。 |
| iOS 不变 | [manifest HEAD 200](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-ios-manifest-head.txt)、[IPA HEAD 200](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/publish-prep/workstation-ios-ipa-head.txt)；设置仍 0.4.20+2189。 |

以上公网回读约 21:36–21:39 +08:00。后续验收要在真实设备登录并验证两种策略的报价、关闭重进后的同键恢复与错误文案；不通过本报告推断个别用户提现请求已经成功。恢复操作先比对现值、审计、HK alias、S3 policy 和 CloudFront ETag，确认没有后继漂移后才从两段备份按相反顺序 CAS 恢复精确前态。数据库写入结果不明时先查审计与现值，不盲重放或回滚，也不删除报价、提现申请或财务记录。
