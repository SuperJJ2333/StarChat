# iOS 0.3.95 / 2132 企业重签交付说明（待企业签名 → 回传后分发）

- 日期：2026-09-17（Asia/Hong_Kong）
- 用户指令：「请你提供 iOS 的 ipa 包给我进行企业签名，之后我会回传给你进行分发」。
- 结论：**同源 iOS 候选已由 GitHub macOS runner 构建完成并留存为 CI 产物**，可直接交给企业签名方重签；
  本机（Windows）**无法构建 iOS**（无 Xcode/macOS），故 iOS 候选只能走 CI 路径（与既有流程一致）。

## 1. 候选来源（与 Android 2132 同源）

| 项 | 值 |
| --- | --- |
| 工作流 | **iOS signed compatibility candidate**（`.github/workflows/ios-0353.yml`，`macos-15` / Xcode 26.3 / Flutter 3.44.9） |
| 运行 | run id **35232603066**，`conclusion=success`，2026-09-17 14:17:43 创建 |
| 源码 commit | **`9fa2c96347adf92bcfa07398cb2212753b9dc0e3`**（`chore(release): bump Android client to 0.3.95+2132`） |
| 与当前 main 的关系 | 其后 main 上的提交（`5e39bf3a`、`e5165733`、`c5035312`、`5a31376`、`369cc5ec`）**全部是文档**，无 App 代码改动 → 该候选的 App 代码与当前 main 等价 |
| 版本 | 工作流从 `pubspec.yaml` 读取：**0.3.95 (build 2132)**（与 Android 正式版同号） |
| 产物 artifact | **`ChatFlow-iOS-signed`**，artifact id `10502073950`，**59,797,494 字节** |
| 产物摘要 | `sha256:4489966bc8e98f0219057cf694e1e98031ae4b7cd82ed1b5a56e12831b52edd9`（GitHub artifact digest） |
| 产物有效期 | 至 **2026-10-01 14:27**（过期后需重新触发工作流） |

**用户可直接下载（不依赖我这边的网络）**：
`https://github.com/SuperJJ2333/StarChat/actions/runs/35232603066` → 页面底部 **Artifacts → `ChatFlow-iOS-signed`**
（zip 内含导出的 `.ipa` 与构建日志；下载需登录有仓库权限的 GitHub 账号）。

## 2. 交给企业签名方时需要说明的事实

| 项 | 值 | 说明 |
| --- | --- | --- |
| Bundle ID | **`com.liuhetong.liuhetongMobile`** | 与当前线上企业版一致；重签必须沿用，否则无法覆盖安装、且与 `manifest.plist` 不匹配 |
| 版本 / 构建号 | `CFBundleShortVersionString = 0.3.95`，`CFBundleVersion = 2132` | 高于线上企业版 0.3.92/2120 |
| 设备族 | iPhone + iPad（`UIDeviceFamily` 含 2） | 与既有企业包一致 |
| 最低系统 | iOS 16.0 及以上 | 工作流断言 `MinimumOSVersion >= 16.0` |
| 后台模式 | `audio`、`voip`、`remote-notification` | 通话与推送依赖，重签时不得丢失 |
| 当前签名（将被替换） | Apple Distribution + profile `ChatFlow_AppStore`，team `HY9Q7Q35S5`，`aps-environment = production` | 这是**我们自己的 App Store 分发签名**，仅作占位；企业方重签会替换证书与描述文件 |
| 加密状态 | 本地 CI 导出的分发 IPA，**非 App Store DRM 加密**（无 FairPlay `cryptid`） | 因此可被第三方重签；企业签名服务通常直接接受 |

**必须提醒企业方（否则会出现「能装但推送/通话失效」）**：

1. 企业描述文件需为 **`com.liuhetong.liuhetongMobile`** 显式 App ID 且**启用 Push Notifications**，保留
   `aps-environment`（建议 production）；若用通配符描述文件，`aps-environment` 会被剥离 → **APNs 推送失效**。
2. 保留 `UIBackgroundModes`（audio/voip/remote-notification）与相关权限说明
   （麦克风/相机 `NSMicrophoneUsageDescription`、`NSCameraUsageDescription`）。
3. 重签后 **Bundle ID 与 CFBundleVersion 必须仍为 `com.liuhetong.liuhetongMobile` / `2132`**。
4. 若企业方偏好**未签名 IPA**（部分签名服务要求），告知我即可：我可以另跑一次
   `flutter build ios --release --no-codesign` 的 CI 作业，产出 `Payload/Runner.app` 打包的未签名 IPA。
   （本次先给**已分发签名**的 IPA，因为它同样可被重签，且已通过工作流内的签名/entitlements 自检。）

## 3. 回传后我这边要做的分发步骤（待用户回传签名 IPA）

1. **校验回传包**（不信任文件名）：解包核对 `Payload/*.app/Info.plist` 的
   `CFBundleIdentifier == com.liuhetong.liuhetongMobile`、`CFBundleShortVersionString == 0.3.95`、
   `CFBundleVersion == 2132`、`UIDeviceFamily` 含 iPad、`UIBackgroundModes` 三项齐全；
   核对签名身份与 `embedded.mobileprovision` 的 Team/App ID/entitlements（含 `aps-environment`）；
   计算 **IPA SHA256** 作为分发基线。
2. **上传不可变文件**：`/opt/starchat/frontend/downloads/ios/ChatFlow-0.3.95-2132-enterprise-<sha8>.ipa`
   （16MiB 分块 + 服务端合并 SHA 门 + `install -m 0644`），旧包 0.3.92/2120 保留为回退。
3. **更新 `downloads/ios/manifest.plist`**：`software-package.url` 指向新 IPA，`bundle-version` 改为 `2132`，
   `bundle-identifier` 不变；保留 HTTPS 与正确的 MIME。
4. **发布 iOS 更新设置**：通过 `SettingService` inspect → apply 更新 `app_ios_*`
   （`app_ios_latest_version=0.3.95`、`app_ios_latest_build=2132`、`app_ios_download_url` 不变或指向安装页），
   写审计；**不动 Android 行**。
5. **公网验证**：`manifest.plist` 200 + `application/xml`、IPA 200/206 + 完整字节数与 SHA256 与基线一致、
   `itms-services://` 安装页可用、未授权接口仍 401。
6. 记录到验证/任务台账并提交推送。

## 4. 本机取件状态（如实记录）

- 我尝试在本机直接下载该 CI 产物以先行校验：GitHub 在本机经本地代理（`127.0.0.1:7897`）链路出现
  **间歇性 TLS 失败**（`schannel: failed to receive handshake`），大文件下载会中途截断；
  已改为「**每个分片重新解析签名 URL + 断点续传 + 40 分钟容错**」的后台取件（脚本
  `artifacts/2026-09-17/ios-2132/fetch_ios_artifact.ps1`），成功后按第 1 节摘要校验。
- 该取件**只影响我这边的预校验**，不影响用户按第 1 节链接直接下载并把 IPA 交给签名方。
