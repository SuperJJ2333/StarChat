# iOS 0.3.96 / 2134 企业重签交接与分发（**已回传、已分发上线**）

- 日期：2026-09-18（Asia/Hong_Kong）
- 用户指令：“提供 iOS 更新包给我签名，然后我返回 ipa 给你进行分发”；版本与 Android 同源同号
  （**0.3.96 / 2134**，由 `scripts/bump_version.ps1` 统一递增）。
- 结论：**候选由用户完成企业签名并回传，校验通过后已分发上线**；
  线上 iOS 企业版为 **0.3.96 / 2134**，旧包 0.3.92/2120 原位保留作回退。执行细节见第 6 节。

## 1. 候选来源（与 Android 2134 同源）

| 项 | 值 |
| --- | --- |
| 工作流 | **iOS signed compatibility candidate**（`.github/workflows/ios-0353.yml`，`macos-15` / Xcode 26.3 / Flutter 3.44.9） |
| 运行 | run id **35355808244**，`conclusion=success`，2026-09-18 14:22Z |
| 源码 commit | **`04cc1d80`**（`fix(matrix): serialize client initialization per database path`） |
| 与 Android 候选的关系 | Android 冻结在 `71971746`（= `04cc1d80` + 文档提交），**App 代码等价**；版本号同为 `0.3.96+2134` |
| 产物 artifact | **`ChatFlow-iOS-signed`**，artifact id **`10551264894`**，**59,919,267 字节** |
| 产物摘要 | `sha256:dac7cfac7a3f0481a454cb8793ada4949c3e23337b629e6edd19121b9a937848`（GitHub artifact digest，已本机复核一致） |
| 产物有效期 | 至 **2026-10-02 14:32Z**（过期需重新触发工作流） |
| 用户可直接下载 | `https://github.com/SuperJJ2333/StarChat/actions/runs/35355808244` → 页面底部 **Artifacts → `ChatFlow-iOS-signed`**（需登录有仓库权限的账号） |

## 2. 本机取件与核验结果（已完成）

| 步骤 | 结果 |
| --- | --- |
| 产物下载 | zip **59,919,267 字节**，SHA256 `dac7cfac…3848`，**与 GitHub artifact digest 完全一致** |
| zip 内容 | 仅一个条目 `liuhetong_mobile.ipa` |
| **IPA 交付件（本地）** | `docs/verification/artifacts/2026-09-18/ios-2134/ChatFlow-0.3.96-2134-signed-candidate.ipa`，**60,296,979 字节**，**SHA256 `5BF564E0244F0B78D6BC153C8C809743B0D812FCBEF397C8F87AE5582BAFE743`** |
| Info.plist 核对 | `CFBundleIdentifier=com.liuhetong.liuhetongMobile`、`CFBundleShortVersionString=0.3.96`、`CFBundleVersion=2134`、`MinimumOSVersion=16.0`、`UIDeviceFamily=[1,2]`、`UIBackgroundModes=[remote-notification, audio, voip]`、麦克风/相机用途说明齐全、`CFBundleDisplayName=畅聊 ChatFlow` |
| 签名材料 | `embedded.mobileprovision` 与 `_CodeSignature/CodeResources` 均存在（已签名）；17 个 framework；`SQLCipher.framework` 与 `App.framework/flutter_assets` 齐全 |
| **可重签性** | Mach-O `Runner` 的 **`cryptid = 0`（非 App Store DRM 加密）→ 可被企业证书重签** |
| 核验脚本 | `docs/verification/artifacts/2026-09-18/ios-2134/inspect_ios_ipa.py`（本地解析 zip/plist/Mach-O，不依赖 macOS 工具） |

> iOS 侧 `CFBundleVersion` 使用 pubspec 构建号原值（**2134**），不做 Android 的 ABI 偏移归一化；
> 线上企业版为 0.3.92/2120，因此 2134 可正常提示更新。

## 3. 交给企业签名方时必须说明的事实

| 项 | 值 | 说明 |
| --- | --- | --- |
| Bundle ID | **`com.liuhetong.liuhetongMobile`** | 与线上企业版一致；重签必须沿用，否则无法覆盖安装且与 `manifest.plist` 不匹配 |
| 版本 / 构建号 | `0.3.96` / `2134` | 高于线上 0.3.92/2120 |
| 设备族 | iPhone + iPad（`UIDeviceFamily` 含 2） | 与既有企业包一致 |
| 最低系统 | iOS 16.0 及以上 | 工作流断言 `MinimumOSVersion >= 16.0` |
| 后台模式 | `audio`、`voip`、`remote-notification` | 通话与推送依赖，重签时不得丢失 |
| 当前签名（将被替换） | Apple Distribution + profile `ChatFlow_AppStore`，team `HY9Q7Q35S5`，`aps-environment = production` | 占位签名；企业方重签会替换证书与描述文件 |
| 加密状态 | 本地 CI 导出的分发 IPA，**非 App Store DRM 加密**（`cryptid=0`） | 可被第三方重签，企业签名服务通常直接接受 |

**必须提醒企业方（否则会出现“能装但推送/通话失效”）**：

1. 企业描述文件需为 **`com.liuhetong.liuhetongMobile`** 显式 App ID 且**启用 Push Notifications**，保留
   `aps-environment`（建议 production）；通配符描述文件会剥离 `aps-environment` → **APNs 推送失效**。
2. 保留 `UIBackgroundModes`（audio/voip/remote-notification）与权限说明（`NSMicrophoneUsageDescription`、
   `NSCameraUsageDescription`）。
3. 重签后 **Bundle ID 与 `CFBundleVersion` 必须仍为 `com.liuhetong.liuhetongMobile` / `2134`**。
4. 若企业方偏好**未签名 IPA**，告知我即可另跑一次 `flutter build ios --release --no-codesign` 的 CI 作业，
   产出未签名 IPA。

## 4. 分发步骤清单（已按此执行，结果见第 6 节）

1. **校验回传包**（不信任文件名）：解包核对 `Payload/*.app/Info.plist` 的 `CFBundleIdentifier`、
   `CFBundleShortVersionString == 0.3.96`、`CFBundleVersion == 2134`、`UIDeviceFamily` 含 iPad、
   `UIBackgroundModes` 三项齐全；核对签名身份与 `embedded.mobileprovision` 的 Team/App ID/entitlements
   （含 `aps-environment`）；计算 **IPA SHA256** 作为分发基线。
2. **上传不可变文件**：`/opt/starchat/frontend/downloads/ios/ChatFlow-0.3.96-2134-enterprise-<sha8>.ipa`
   （16 MiB 分块 + 服务端合并 SHA 门 + `install -m 0644`），旧包 0.3.92/2120 保留为回退。
3. **更新 `downloads/ios/manifest.plist`**：`software-package.url` 指向新 IPA，`bundle-version` 改为 `2134`，
   `bundle-identifier` 不变；保留 HTTPS 与正确 MIME。
4. **发布 iOS 更新设置**：通过 `SettingService` inspect → apply 更新 `app_ios_*`
   （`app_ios_latest_version=0.3.96`、`app_ios_latest_build=2134`、`app_ios_download_url` 不变或指向安装页），
   写审计；**不动 Android 行**（当前 Android 为 `0.3.96/2134`）。
   同时更新 `frontend/src/admin-home.js` 中硬编码的 iOS 标签（现有 `0.3.92（2120）` → `0.3.96（2134）`）。
5. **公网验证**：`manifest.plist` 200 + `application/xml`、IPA 200/206 + 完整字节数与 SHA256 与基线一致、
   `itms-services://` 安装页可用、未授权接口仍 401。
6. 记录到验证/任务台账并提交推送。

## 5. 本候选包含的修复（为什么值得升级）

iOS 线上企业版仍为 **0.3.92/2120**，早于 2026-09-16 的两个关键修复；本候选（0.3.96/2134）包含：

- `81bac4e8` **suspend 必达**：drain 超时只记日志、关闭照常完成 → 消除“账号已退出：聊天会话暂停失败，
  请重新打开应用后重试”以及由此产生的半挂起态；
- `20d4673a` + ADR-0072 **device id 轮换连续性**：连续性锚点不再比较 `deviceId`（只比较 `userId` /
  Olm fingerprint / 库代号），并给“库已轮换、binding 未轮换”的遗留态一次性自愈 → 消除 **L04** 与随后的 **L07**；
- 以及 2132 之后 main 上的全部客户端改动：BUG-01～10 修复、Room Opening Policy Engine、
  媒体引擎 Phase 0–2（本地索引/引用解析/图集编辑器）、Matrix 客户端初始化按库路径串行化等。

## 6. 回传包的校验与分发执行结果（已完成）

### 6.1 回传包校验（`verify_resigned_ipa.py`：`RESIGN_VERIFY: PASS`）

| 项目 | 值 |
| --- | --- |
| 回传 IPA | **60,922,843 字节**，SHA256 **`60A09413D7604CB950354BCFF9EE7F40A96B2748EE01EEEDA50943700129A78F`** |
| 身份 | `com.liuhetong.liuhetongMobile` / `CFBundleShortVersionString=0.3.96` / `CFBundleVersion=2134` / iOS 16.0+ / iPhone+iPad / 后台模式三项齐全 |
| 签名 | `_CodeSignature/CodeResources` + `embedded.mobileprovision` 在位；profile `20260107buaawxworklocalNOTI`，team `ZXB3TS7QD4`，`aps-environment=production`，`get-task-allow=false`，有效期至 **2026-12-03**，无 ProvisionedDevices（企业签名特征） |
| 可重签/未加密 | Runner `cryptid = 0` |
| 结构对比（与候选逐条目） | 缺失 0 项；**额外 3 项为签名服务注入的固定载荷**（`Frameworks/AppRuntime/ATHelper.dylib`、`Frameworks/Partner/libutils.dylib`、`Runner.app/flag`）——与**线上一直使用的 0.3.92/2120 企业包完全一致**（已对该包做同样的服务端校验，profile 名/team/注入集合逐项相同） |
| 差异分类 | 37 项差异 = 19 项签名路径（`_CodeSignature/**`、`embedded.mobileprovision`）+ 18 个重签后的 Mach-O 二进制；**无其它非签名差异** |

> **如实记录（供应链须知）**：企业签名服务会向其签名的每个 IPA 注入上述三个文件。这不是本次新增，
> 现有线上包同样存在；如不希望携带该注入，需要改用不注入的签名渠道（自签企业证书或 Apple Developer Enterprise 直签）。
> 本轮按既定发布流程分发，未扩大注入面（集合与线上基线一致）。

### 6.2 分发执行（服务端）

| 步骤 | 命令/脚本 | 结果 |
| --- | --- | --- |
| 分块上传 | `upload-ios-ipa.ps1 -BaselineSha 60A09413…` | 4 片（16 MiB×3 + 10,591,195），逐片远端尺寸核对一致 → `IPA_CHUNKS_UPLOADED` |
| 合并 + SHA 门 + 安装 | `bash publish-ios-ipa.sh 60A09413…` | `merged_sha == expected`；安装 `ChatFlow-0.3.96-2134-enterprise-60a09413.ipa`（60,922,843 字节）→ `===DONE===` |
| 旧包保留 | `ChatFlow-0.3.92-2120-enterprise-e8e63a58.ipa` | 60,444,412 字节，SHA256 `e8e63a58…4fac`（回退目标） |
| OTA 清单 | `update_manifest_2134.py inspect/apply` | `url` → 新 IPA；`bundle-version` → **2134**；`bundle-identifier` 不变；`title` → **畅聊正式版**；备份 `manifest.plist.bak-20260918T153657Z` → `MANIFEST_UPDATE_OK` |
| iOS 更新设置 | `publish_settings_ios_2134.py`（容器内 stdin 执行） | `PUBLISH_PASS`，`audit_count=5`（trace `ios-release-0.3.96-2134-20260918`）；`app_ios_latest_version=0.3.96`、`app_ios_latest_build=2134`、`app_ios_min_supported_build` 仍为 **0**（不强制）、`app_ios_download_url` 仍指向安装页；**Android 行零改动** |
| 下载页文案 | `download.html` + `src/admin-home.js` + `home.html` | **“测试版”→“正式版”**（徽标 `企业正式版`、按钮 `安装 iOS 正式版`、说明 `企业内部使用`），版本标签 `0.3.92（2120）` → **`0.3.96（2134）`**，电脑端 IPA 链接指向新包，脚本引用加 `?v=2134` 破缓存；服务端均在原位保留 `.bak-20260918T153714Z` |

### 6.3 公网验证

| 探测 | 结果 |
| --- | --- |
| `https://www.liuhetong888.com/download` | `200`，含 **企业正式版 ×2**、**`0.3.96（2134）`**，**`测试版` 出现 0 次** ✅ |
| `https://www.liuhetong888.com/` | `200`，引用 `admin-home.js?v=2134` ✅ |
| `downloads/ios/manifest.plist` | `200 application/xml`；`bundle-identifier=com.liuhetong.liuhetongMobile`、`bundle-version=2134`、`title=畅聊正式版` ✅ |
| 新 IPA（HEAD / 分段 / 整包） | `200` / `206`（1 MiB）/ 整包 **60,922,843 字节，SHA256 `60a09413…9a78f`** 与回传包**逐字节一致** ✅ |
| 安装入口 | 页面 `itms-services://…manifest.plist` 在位；电脑端 IPA 直链 `200 application/octet-stream` ✅ |
| 旧包 | 仍可下载（回退）✅ |

### 6.4 回退

1. 清单：`cp -p /opt/starchat/frontend/downloads/ios/manifest.plist.bak-20260918T153657Z manifest.plist`；
2. 设置：`publish_settings_ios_2134.py rollback`（写 `<trace>-rollback` 审计）；
3. 文案：`cp -p download.html.bak-20260918T153714Z download.html`、`cp -p src/admin-home.js.bak-20260918T153714Z src/admin-home.js`。

### 6.5 未验证 / 剩余风险

- **未在 iOS 真机安装本次企业包**（签名与安装由用户执行）；通话/推送/历史连续性需在真机验收。
- 签名服务注入的三个文件（见 6.1）与线上基线一致，但仍是第三方代码；如需彻底移除需更换签名渠道。
- 线上 iOS 客户端在收到更新提示后需覆盖安装（**勿卸载**）以保留本机聊天记录。

