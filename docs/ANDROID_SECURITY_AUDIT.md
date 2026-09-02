# ChatFlow Android 误报安全审计报告（a.gray.BulimiaTGen.f）

**日期**：2026-09-02
**范围**：`apps/mobile_flutter`（Android 工程）+ 全部 Flutter 插件依赖 + Release APK 产物
**目标**：定位 Release APK 被识别为 `a.gray.BulimiaTGen.f` 的可疑来源，消除误报来源与不必要的高风险行为
**合规声明（需求 13）**：本次审计与整改**不包含**任何规避、绕过或欺骗杀毒软件的手段——不更换签名、不修改代码特征、不使用壳/加固/字符串混淆对抗。所有措施均为"移除不必要的高风险行为 + 消除权限/依赖层面的误报来源 + 走厂商误报申诉"。

---

## 0. 结论速览

| 风险等级 | 发现 | 处置 |
| --- | --- | --- |
| **高（最可能误报源）** | 应用内更新弹窗会**下载 APK 并拉起安装**（`app_update_dialog.dart` → `launchAppDownload` → url_launcher 打开自建域名 APK 链接） | 属正常自更新，但为灰名单（Bulimia 类="自动下载/诱导安装 APK"）教科书式特征。已在诊断构建整体摘除（`LIUHETONG_IN_APP_UPDATE=false`）；生产保留，建议向厂商申诉时附本报告 |
| **高** | `USE_FULL_SCREEN_INTENT` + `MainActivity` 的 `showWhenLocked`/`turnScreenOn`（来电锁屏全屏弹窗） | 通话必需；诊断构建已移除/关闭 |
| **中** | `SCHEDULE_EXACT_ALARM`（消息/通话提醒精确闹钟） | 提醒功能需要；诊断构建已移除 |
| **中** | 库注入的 `WRITE_EXTERNAL_STORAGE`（video_compress）与 `BLUETOOTH≤30`（flutter_webrtc） | 非聊天必需；诊断构建已裁剪，生产建议下版本用 `tools:node="remove"` 移除（见 §4） |
| **低（正常，无法消除）** | R8 混淆（"TGen"泛型特征常见于混淆应用）、WebRTC/SQLCipher/OLM/OpenSSL 原生库、录音+相机+前台服务组合（音视频通话） | 均为功能必需、来源可归因；走申诉附材料 |

**未发现**（逐项验证见 §5/§6）：READ_SMS、RECEIVE_SMS、QUERY_ALL_PACKAGES、REQUEST_INSTALL_PACKAGES、SYSTEM_ALERT_WINDOW、无障碍服务、通知监听、READ_CALL_LOG、设备管理员、UsageStats；动态 DEX 加载、下载执行代码、Runtime.exec/shell、root 检测代码、隐藏组件、自启动（BOOT_COMPLETED）、未知 native so、debug 签名。

---

## 1. pubspec.yaml 第三方依赖清单（全部运行时依赖）

共 37 个运行时依赖 + 2 个开发依赖。按风险面分类：

| 类别 | 依赖 | 说明/风险面 |
| --- | --- | --- |
| 网络 | `http` | Dart 层 HTTP 客户端，无原生代码 |
| 安全存储 | `flutter_secure_storage` | Android Keystore + EncryptedSharedPreferences |
| 本地存储 | `shared_preferences`, `path_provider`, `path`, `sqflite_common_ffi`, `sqlcipher_flutter_libs` | SQLCipher 为加密 SQLite（原生 `libsqlcipher.so`），E2EE 本地缓存必需 |
| 加密域 | `matrix`（Dart Matrix SDK）, `flutter_olm`（`libolm.so`）, `flutter_openssl_crypto`（`libcrypto.so`/`libflutter_openssl_crypto.so`, 依赖 `jni`→`libdartjni.so`）, `crypto` | E2EE 必需，全部知名开源 |
| 媒体选择/处理 | `image_picker`, `file_selector`, `image_cropper`（内嵌 uCrop 2.2.10）, `flutter_image_compress`, `photo_manager`, `video_compress`, `video_player`, `image_picker` | 见 §4 权限归因；`video_compress` 注入 `WRITE_EXTERNAL_STORAGE` |
| 音视频通话 | `flutter_webrtc`, `webrtc_interface` | `libjingle_peerconnection_so.so`；注入 `BLUETOOTH≤30` |
| 语音/音频 | `record`, `audioplayers`, `speech_to_text` | 系统 SpeechRecognizer，无第三方 SDK |
| 通知/提醒 | `flutter_local_notifications`, `timezone` | 精确闹钟路径需要 `SCHEDULE_EXACT_ALARM` |
| UI/其它 | `flutter_svg`, `emoji_picker_flutter`, `cached_network_image`, `flutter_cache_manager`, `wakelock_plus`, `webview_flutter`, `url_launcher`, `package_info_plus`, `uuid`, `characters` | 均为 pub.dev 知名插件；`webview_flutter` 为系统 WebView 封装 |
| 开发依赖 | `flutter_lints`, `flutter_launcher_icons` | 不进入 APK |

**无**广告、统计、Push、设备指纹类 SDK（见 §8）。

## 2. Gradle 检查（app/build.gradle.kts、settings.gradle.kts）

- `settings.gradle.kts`：插件仓库仅 `google()` / `mavenCentral()` / `gradlePluginPortal()`；AGP 9.0.1、Kotlin 2.3.20、Flutter 插件加载器 1.0.0。**无自建/可疑 maven 仓库**。
- `android/app/build.gradle.kts`：唯一第三方依赖 `com.android.tools:desugar_jdk_libs:2.1.4`（Google 官方）。release 构建启用 `isMinifyEnabled`（R8）+ `isShrinkResources`，proguard 规则仅用于防误报去混淆崩溃，未做字符串/包名伪装。
- 其余 Android 依赖全部由 Flutter 插件各自的 gradle 文件从 pub.dev 缓存内源码构建；唯一外部二进制依赖为 `image_cropper` 内嵌的 `com.github.yalantis:ucrop:2.2.10`（知名开源裁剪库，源码公开）。
- 2026-09-02 起新增 flavor：`standard`（生产，行为不变）/ `minimal`（诊断构建，见 §11）；生产构建命令需 `--flavor standard`（runbook 已同步）。

## 3. 最终 Merged AndroidManifest

来源：`flutter build apk --release`（0.3.26+29, arm64）合并产物
`apps/mobile_flutter/build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml`
（flavor 化后位于 `merged_manifest/standardRelease/`）。要点：

- **权限（18 项）**：见 §4 全表。
- **组件**：`MainActivity`（exported，LAUNCHER；含 `showWhenLocked`/`turnScreenOn`，服务于锁屏来电）、`com.yalantis.ucrop.UCropActivity`（非导出，头像裁剪）、`com.dexterous.flutterlocalnotifications.ForegroundService`（非导出，type=microphone|camera，提醒/通话保活）。**无其它导出组件、无隐藏 activity/service/receiver**。
- **queries**：仅 `ACTION_PROCESS_TEXT`（text/plain）——文本选择处理，无 QUERY_ALL_PACKAGES。
- **App Links/深链**：无。

## 4. 权限全表（合并清单 18 项）

| 权限 | 功能需要 | 引入方 | 可否删除 |
| --- | --- | --- | --- |
| INTERNET | 全部网络功能 | 自有 manifest | 否 |
| ACCESS_NETWORK_STATE | 网络可用性判断（ connectivity 检查） | 自有 manifest | 否 |
| READ_MEDIA_IMAGES / READ_MEDIA_VIDEO / READ_MEDIA_VISUAL_USER_SELECTED (13+) | 相册选择器读取图片+视频（视频选择是 0.3.26 修复的根因权限） | 自有 manifest | 否 |
| READ_EXTERNAL_STORAGE (≤32) | Android 12- 相册读取 | 自有 manifest | 否（旧设备需要） |
| CAMERA | 拍摄/录像/视频通话 | 自有 manifest | 否 |
| RECORD_AUDIO + MODIFY_AUDIO_SETTINGS | 语音消息、语音/视频通话 | 自有 manifest | 否 |
| POST_NOTIFICATIONS (13+) | 消息/通话通知 | 自有 manifest | 否 |
| SCHEDULE_EXACT_ALARM (12+) | 消息提醒/通话回访的精确闹钟（flutter_local_notifications） | 自有 manifest | **可议**：改 inexact 闹钟可删（提醒时间允许 ±分钟级误差）；诊断构建已移除 |
| VIBRATE | 长按反馈/来电震动 | 自有 manifest | 否 |
| WAKE_LOCK | 通话屏幕常亮（wakelock_plus）、Matrix 同步 | 自有 manifest | 否 |
| USE_FULL_SCREEN_INTENT | 锁屏来电全屏弹窗 | 自有 manifest | 通话功能需要；**高危启发式**；诊断构建已移除 |
| FOREGROUND_SERVICE + FOREGROUND_SERVICE_MICROPHONE/CAMERA | 通话/提醒前台服务保活 | 自有 manifest | 通话需要；诊断构建移除 typed 权限 |
| **WRITE_EXTERNAL_STORAGE** (注入，未声明 maxSdk) | 无直接使用——video_compress 插件清单注入（其转码临时文件在旧设备兜底） | **video_compress 3.1.4** | **可删**（建议生产下版本 `tools:node="remove"`；Android 10+ 无影响，9- 仅影响该插件内部临时文件兜底） |
| **BLUETOOTH** (注入，≤30) | WebRTC 蓝牙耳机路由（AudioUtils） | **flutter_webrtc 0.12.11** | 可删（仅影响 Android 10- 蓝牙话筒）；诊断构建已移除 |
| DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION（自定义 signature 级） | AGP 为 13+ 动态 receiver 自动生成的保护权限 | 构建系统自动 | 否（系统行为） |

**特别检查清单（需求 5）**：READ_SMS / RECEIVE_SMS / QUERY_ALL_PACKAGES / REQUEST_INSTALL_PACKAGES / SYSTEM_ALERT_WINDOW / 无障碍（AccessibilityService）/ 通知监听（NotificationListenerService）/ READ_CALL_LOG / Device Admin（device_admin.xml）/ UsageStats（PACKAGE_USAGE_STATS）——**合并清单中全部为 0 命中**（grep 验证），未申请、未声明。

## 5. 高危行为检查（需求 6）

| 检查项 | 结果 | 证据 |
| --- | --- | --- |
| 动态 DEX 加载（DexClassLoader/PathClassLoader/InMemoryDex） | **未发现** | 全部 195 个 pub 缓存插件 android 源码 grep 0 命中；自有 Dart 代码无相关调用 |
| 下载并执行代码 | **未发现** | 同上；APK 内无 assets 下的 dex/jar/so 载体 |
| APK 自动下载安装 | **部分存在**：应用内更新弹窗 `launchAppDownload(apkUrl)` 用 url_launcher 打开自建域名 APK 直链，交由浏览器/下载管理器下载后由用户确认安装。**无静默安装、无 REQUEST_INSTALL_PACKAGES**，但"下载 APK→拉起安装"正是 Bulimia 类灰名单的核心启发式 | `lib/features/update/app_update_dialog.dart:50`、`lib/features/update/app_update.dart:86` |
| Runtime.exec / ProcessBuilder / shell 命令 | **未发现**（自有代码 + 全部插件源码 grep 0 命中） | grep 证据 |
| root 检测/提权（su、Superuser） | **未发现** | grep 0 命中 |
| 隐藏组件（exported=true 且无入口、enabled=false 切换） | **未发现**：导出组件仅 MainActivity | §3 组件清单 |
| 自启动滥用（BOOT_COMPLETED 等） | **未发现**（合并清单 0 命中）；`USE_FULL_SCREEN_INTENT`/`showWhenLocked` 属"锁屏拉起"类高危行为（来电用），诊断构建已关闭 | grep 证据 |
| 无障碍服务 | **未发现** | 无 AccessibilityService 声明/代码 |
| 未知 native so | **未发现**：`libapp/libflutter/libc++_shared`（Flutter）、`libjingle_peerconnection_so`（WebRTC）、`libolm`（Matrix E2EE）、`libsqlcipher`（加密本地库）、`libcrypto`/`libflutter_openssl_crypto`/`libdartjni`（flutter_openssl_crypto→jni）、`libdatastore_shared_counter`（androidx datastore，shared_preferences）。全部知名开源、版本可溯源至 pubspec.lock | `unzip -l` 全量列出 |

## 6. 灰名单误报机理说明（为什么是 BulimiaTGen）

`a.gray.BulimiaTGen.*` 为"灰色应用-泛型"启发式判定（TGen = 通用特征引擎），常见触发组合是：
**① 下载/传播 APK 并诱导安装；② 锁屏/全屏弹窗能力；③ 精确闹钟/前台服务保活；④ 高强度混淆（R8）导致特征不可读；⑤ 敏感权限组合（录音+相机+通知）**。

本应用命中 **①②③④⑤ 的组合**，且每个单点都有正当用途（自更新、来电、提醒、通话、保护隐私的 E2EE 客户端）。这类"行为组合型"误报通常无法通过单点消除彻底解决，正确处置是：
1. 减少非必需项（诊断构建已给出裁剪基线，见 §11）；
2. 用 §12 的二分流程锁定具体触发点；
3. 向检测厂商提交**误报申诉**（附本报告、证书指纹 `b4784ac3…22f6`、APK 下载直链与源码仓库说明）。

## 7. .aar / .jar / .so 来源（需求 7）

- **.jar**：APK 内 **0 个** jar（全部依赖为源码编译进 classes.dex）。
- **.aar**：无本地 aar；外部二进制仅 uCrop 2.2.10（经 maven，源码公开，image_cropper 引入）。
- **.so（10 个，全部归因）**：见 §5 表。
- 签名文件：META-INF 为标准 v2 签名块，无多余可执行条目。

## 8. 广告 / 统计 / Push / RTC / 设备指纹 SDK（需求 8）

| 类别 | 结论 |
| --- | --- |
| 广告 SDK | **无**（无 admob/unity/pangle 等） |
| 统计/埋点 SDK | **无第三方**（会话内"统计助手"为本地工具逻辑，无数据外发 SDK） |
| Push SDK | **无第三方**（无 FCM/极光/个推；通知全部为本地通知 flutter_local_notifications） |
| RTC | flutter_webrtc（开源 WebRTC，`libjingle_peerconnection_so.so`）——1v1 音视频通话必需 |
| 设备指纹 | **无**（package_info_plus 仅读取本应用版本号；无 oaid/gaid/设备指纹采集） |

## 9. Release 签名确认（需求 9）

- `android/app/build.gradle.kts` release 构建签名取自 `key.properties`（不入库的 `storeFile`），`debug` 与 `release` 使用不同签名配置；合并清单与产物核对均由 release 签名配置出包。
- `apksigner verify --verbose`：`Verified using v2 scheme: true`（v1/v3 false），**未出现 "Android Debug" 证书主体**。

## 10. 证书 SHA-256 与一致性（需求 10）

- 证书主题：`CN=Liuhetong, OU=Mobile, O=Liuhetong, L=Hong Kong, ST=HK, C=HK`
- **证书 SHA-256：`b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6`**
- 一致性验证：`app-arm64-v8a-release.apk`、`app-armeabi-v7a-release.apk`、`app-x86_64-release.apk`、诊断构建 `app-minimal-release.apk` 以及已发布到 `downloads/` 的 0.3.26 三包（SHA-256 见 `docs/verification/2026-09-02-release-0.3.26.md`）**全部为同一证书**。生产始终使用 `key.properties` 指定的同一 keystore；keystore 不入库、不轮换（轮换需走双签名过渡，见 runbook）。

## 11. 最小 Release 诊断构建（需求 11）

**说明**：本项目的聊天域是 **Matrix（Synapse + E2EE）**，不是 OpenIM——工程中不存在 OpenIM SDK。最小构建保留"登录 + Matrix E2EE 聊天 + 必要网络"，裁剪全部非聊天必需的高危行为。

已创建并构建成功：

```powershell
flutter build apk --release --flavor minimal --target-platform android-arm64 `
  --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com `
  --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com `
  --dart-define=LIUHETONG_IN_APP_UPDATE=false
```

- 产物：`app-minimal-release.apk`（applicationId `com.liuhetong.mobile.audit`，versionName `0.3.26-audit`，同一正式签名，可与生产包共存安装）。
- 实现方式（不改生产行为）：
  - Gradle flavor `minimal`：`android/app/src/minimal/AndroidManifest.xml` 以 `tools:node="remove"` 裁剪 `USE_FULL_SCREEN_INTENT`、`SCHEDULE_EXACT_ALARM`、`FOREGROUND_SERVICE_MICROPHONE/CAMERA`、库注入的 `WRITE_EXTERNAL_STORAGE`、`BLUETOOTH`；并用 `tools:replace` 关闭 MainActivity 的 `showWhenLocked`/`turnScreenOn`。已用 aapt 复核合并结果（上述权限全部消失）。
  - Dart 门控：`AppConfig.inAppUpdateEnabled`（`--dart-define=LIUHETONG_IN_APP_UPDATE=false`）整体跳过更新检查/下载弹窗——摘除"下载 APK 并拉起安装"行为。
  - 保留：登录、Matrix 聊天、图片/语音消息、相册选择、通知（非精确）、网络。
- **standard 构建回归**：`flutter build apk --release --flavor standard` 构建通过，生产行为与 0.3.26 完全一致（更新弹窗等全部保留）；`flutter analyze` 0 告警、`flutter test` 510 passed。
- 注意：flavor 化后**所有 Android 构建必须显式 `--flavor standard|minimal`**（runbook 已更新）。

## 12. 二分测试方案（逐个恢复 SDK/权限/行为）

**原则**：同一台对照机 + 同一杀软引擎与病毒库版本 + 同一测试动作（安装→启动→登录→收发一条文本→静置 10 分钟→重启一次），每步只改一个变量，用 §11 的 minimal 基线为起点"逐项恢复"，直到命中触发项。

| 步骤 | 变更（相对 minimal） | 恢复内容 | 对应嫌疑 |
| --- | --- | --- | --- |
| M0 | —（基线） | — | 若 M0 仍报 → 触发面在 Flutter 引擎/R8 混淆本身或网络行为，转走申诉 |
| M1 | Dart 门控打开 | 应用内更新"下载 APK→安装"行为 | **头号嫌疑** |
| M2 | + manifest | `USE_FULL_SCREEN_INTENT` + MainActivity `showWhenLocked/turnScreenOn` | 锁屏全屏拉起 |
| M3 | + manifest | `SCHEDULE_EXACT_ALARM` | 精确闹钟 |
| M4 | + manifest | `FOREGROUND_SERVICE_MICROPHONE/CAMERA`（typed 前台服务） | 保活组合 |
| M5 | + manifest | `WRITE_EXTERNAL_STORAGE`、`BLUETOOTH`（库注入项） | 非必需权限面 |
| M6 | + 依赖 | `video_compress`（同时带回其注入权限，需保留 remove 才算单变量） | 转码器 |
| M7 | + 依赖 | `flutter_webrtc` | WebRTC/`libjingle` |
| M8 | + 依赖 | `photo_manager`、`flutter_local_notifications` | 媒体/通知 |
| M9 | + 依赖 | `speech_to_text`、`record`、`audioplayers` | 语音链路 |
| M10 | = standard | 其余全部（webview、url_launcher 全量使用等） | 复现生产触发面 |

**执行要点**：
1. 每步构建后先 `aapt dump permissions` 留档合并清单差异；
2. 命中触发项后，对该项再做一次"半分"（例如 M1 命中 → 仅保留"检查版本+弹窗（不含打开 APK 链接）"→ 定位到是"下载行为"还是"弹窗本身"）；
3. 全程不做任何特征伪装；命中的必需项以**误报申诉**解决（腾讯/华为/小米等厂商均受理，附证书指纹、源码说明与最小复现说明）；
4. 对 `WRITE_EXTERNAL_STORAGE`/`BLUETOOTH` 两个库注入权限，无论二分结果如何都建议在生产 manifest 永久 `tools:node="remove"`（无功能损失面，直接缩小误报面）。

## 13. 合规声明（需求 13）

本审计全程未采取以下手段：更换/多签名、修改代码或字符串以规避特征、加壳/加固/虚拟化、反射隐藏、分渠道包差异化伪装、对抗扫描环境检测。所有改动仅为：
1. 移除非必需权限与高危行为（minimal 诊断构建 + 建议的生产裁剪项）；
2. 明确每个保留项的正当用途并归档证据；
3. 通过厂商误报申诉流程解决剩余判定。

## 附：证据文件与产物

- Release 合并清单（0.3.26）：`apps/mobile_flutter/build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml`
- 诊断构建：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-minimal-release.apk`；standard 回归：`app-standard-release.apk`
- 权限/组件/证书核对：`aapt dump permissions|xmltree`、`apksigner verify --print-certs`（记录于本文 §3/§4/§10）
- 插件源码扫描：pub 缓存 195 个插件的 android 源码，模式 `Runtime\.getRuntime|ProcessBuilder|DexClassLoader|PathClassLoader` → 0 命中
- 相关文档：`docs/runbooks/mobile-release.md`（构建命令变更）、`docs/verification/2026-09-02-release-0.3.26.md`（当前线上版本）
