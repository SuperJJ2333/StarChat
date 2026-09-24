# v0.4.7 Android 更新弹窗与 iOS IPA 交付证据

日期：2026-09-24 HKT。实施计划见 [v0.4.7 交付计划](../superpowers/plans/2026-09-24-android-047-ios-ipa.md)，任务状态见 [任务记录](../workflow/tasks/2026-09-24-android-047-ios-ipa.md)。

## 候选身份与边界

- 用户明确选定版本显示名 v0.4.7；构建号 2172，较现有正式 Android 2165 与 MI 6 内部 Debug 2171 均递增。MI 6 当前内部包显示名 0.4.10，故其更新弹窗比较不能代表正式 0.4.6 客户端。
- 冻结源码：`codex/online-room-refresh` 提交 `e7ba46a43ab8046e9ffe932827f20ea59820e996`，tree `ba34a80fcd1d8ae881f0a82d8149278fd244f134`；已推送远端并触发 iOS CI [run 35969111874](https://github.com/SuperJJ2333/StarChat/actions/runs/35969111874)。两端构建以此提交的移动端内容为候选；后续仅文档变化不改变其源码身份。
- 生产发布前态于 2026-09-24 15:25 HKT 只读核对：Android `0.4.6/2165`、`latest-arm64.apk` 指向 `ChatFlow-0.4.6-build2165-arm64.apk`（80,718,878 字节），最低支持构建号 3；iOS `0.3.102/2144`。API 镜像 `c41dfffc…`、worker `90696ffa…` healthy、重启 0。

## 源码门禁

| 门禁 | 结果 | 证据 |
| --- | --- | --- |
| `scripts/bump_version.ps1 -Version 0.4.7+2172` | exit 0；版本合同 2 passed | pubspec 与 AppConfig 均为 0.4.7+2172 |
| `flutter pub get --offline --enforce-lockfile` | exit 0 | `flutter-pub-get.log`，本任务 artifacts |
| `flutter test --no-pub` | exit 0；4120 passed / 9 skipped，02:43 | `flutter-full.log`，本任务 artifacts |
| `flutter analyze --no-pub` | exit 0；No issues found | `flutter-analyze.log`，本任务 artifacts |
| `python -m pytest tests/mobile/test_release_metadata.py tests/mobile/test_app_build_contract.py -q` | exit 0；16 passed | 本次命令记录 |
| `git diff HEAD^ HEAD --check` | exit 0 | 144 文件提交前门禁；无敏感密钥/包文件被纳入提交 |

上述本地日志在 `C:\Users\Administrator\.codex\visualizations\2026\09\23\01a0d059-a062-7cd3-b140-f324cc27a599\docs\verification\artifacts\2026-09-24\android-047-ios-ipa\`。同一已冻结功能源码在上一任务记录有完整后端 `verify.ps1`、Flutter、前端测试与生产 API/worker 发布证据。本轮只改变移动版本常量及 iOS workflow 触发分支，未重复无关后端构建。

## 独立审查

规格符合性先行，随后质量/安全审查：`/root/final_audit` 复核两轮功能台账、0.4.7/2172 版本、Android/iOS 发布隔离及 CI `if: false` 的 TestFlight 上传；144 文件无凭据/包混入，staged diff 校验通过。审查未发现候选源码阻断。剩余工件与生产门禁须以本记录后续实测结果为准。

## 构建、发布与交接

### Android ARM64 正式工件

- `flutter build apk --release --no-pub --flavor standard --target-platform android-arm64`，保留 Matrix/Business/Getui 的三个 HTTPS dart-define。首次 Gradle 因既有 dev-only `integration_test` 生成注册项编译失败；精确移除该生成块后重试 exit 0，并按备份恢复生成文件原字节。首轮失败与重试日志均留在本任务 `android/` 产物目录，不冒称首轮成功。
- 按现行手册使用 Apktool 2.12.1 常规重建、build-tools 36.0.0 的 16K zipalign、固定 P12 签名。脚本 exit 0 且输出 `BUILD_2172_PASS`。最终 APK：80,915,486 字节，SHA256 `7741e45a9c2c8b70a0ad46977a657f96b86f9500f7a1fa4bd04155e08906c773`；包 `com.liuhetong.mobile`、0.4.7/2172、仅 arm64-v8a、非 debuggable。证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，apksigner v2/v3、签名后 zipalign、原/最终 verify_android_release 均通过。
- 独立重解包对照：338 项原生库/Flutter 资产字节一致、25,346 个类语义一致、清单语义一致；6 个 DEX 与 resources 由常规工具重建。`artifact.json`、`verification.json` 及原始检查日志在 `D:\pythonProject\outsource\StarChat\.worktrees\online-room-refresh\docs\verification\artifacts\2026-09-24\android-047-ios-ipa\android\`。
- MI 6 安装烟测：`adb devices -l` 无在线设备，`cbd0156b` 不可达；在安装前停止。未执行 `adb install`、卸载或清数据。此缺口只影响真机验收，不改变工件/发布门禁的实际结果。

### Android 生产发布

- 本地 `release_metadata.py prepare` exit 0，仅生成 Android `app_latest_version=0.4.7`、`app_latest_build=2172`、不可变 APK URL。发布记录 `release.json` 与最终包字节数一致；元数据合同 16 项通过。
- 在 `/opt/starchat/releases/android-047-2172-20260924/` 建 0700 私有发布目录，上传发布脚本与不可变候选。服务器 `final.apk` SHA256 与本地均为 `7741e45a…`。`publish-android.py` 将已验证字节落到 `/opt/starchat/frontend/downloads/ChatFlow-0.4.7-build2172-arm64.apk`，原子切换 `latest-arm64.apk`，验证 HEAD 后由 `release_metadata.py publish` 通过公开 SettingService 发布 Android 三项元数据并单独审计更新说明。发布输出：`UPLOAD_IDENTITY_PASS`、`PUBLISH_PASS`、`ANDROID_2172_PUBLISHED`，exit 0。
- 发布后 `release_metadata.py check` 输出 `METADATA_CHECK_PASS`。公网 HTTPS 不可变 APK 与 latest-arm64 的 HEAD 均为 200、`Content-Length: 80915486`；别名目标是 `ChatFlow-0.4.7-build2172-arm64.apk`。未执行发布阶段的完整公网回拉验包。业务更新 API 未授权查询仍返回 401。
- 重新读取实际 Settings：Android 0.4.7/2172、URL 指向不可变 APK，说明为“优化群公告提醒与编辑、群管理；朋友圈支持 GIF、视频及互动消息；完善‘我’页导航、邀请码历史、资料输入限制和钱包提示。”；最低支持构建号仍 3。四条 `settings.update`/`ADMIN_SETTING_UPDATED` 审计分别对应版本、构建号、URL、说明，`ANDROID_2172_READBACK_AUDIT_PASS`。iOS 版本 0.3.102/2144、最低构建号 3、说明及 HTTPS 安装入口均未改变。
- 发布后再次读取 API/worker 容器：镜像仍分别为 `c41dfffc…` / `90696ffa…`，均 healthy、重启 0；本次未改业务镜像或 schema。
- 服务器私有目录保存 `android-alias-before.json`、`android-settings-before.json`、`android-settings-after.json`；元数据发布器的 0700 备份在 `/opt/starchat/docs/verification/artifacts/2026-09-24/android-047-2172/`。旧不可变 0.4.6 APK 保留；回退应先读当前设置/审计，不能直接重放旧发布记录。

### iOS 待企业重签 IPA

- [macOS CI run 35969111874](https://github.com/SuperJJ2333/StarChat/actions/runs/35969111874) 于 2026-09-24 15:20–15:31 HKT 在提交 `e7ba46a4…` 上完成，job `107534395502` 成功。推送集成 Flutter 测试与 25 个原生通话/钥匙串测试通过；CI 签名身份和生产 APNs profile 安装、`codesign --verify --deep --strict`、bundle ID/版本/iPad/后台音频与推送/SQLCipher 载入顺序及共享统计资产检查均通过，日志有 `SQLCIPHER_LOAD_ORDER_PASS` 与 `IPA signature, production APNs, iPad and permission declarations verified`。TestFlight 上传步骤由 workflow `if: false` 禁用。
- `ChatFlow-iOS-signed` artifact ID `10795826082`，ZIP 60,431,017 字节，SHA256 `fc768347866f615271fcbd1453df8ca3be26f55a5ce000d6483cc74135ef7f64`，与 GitHub artifact digest 一致。提取唯一 IPA 并读包内 Info.plist：`com.liuhetong.liuhetongMobile`、0.4.7/2172、iOS 16.0 起、iPhone/iPad、音频/VoIP/远程通知、SQLCipher 文件在位，统计资产 SHA256 `89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5` 与源码一致。
- 可交企业签名方的文件：`D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-24\android-047-ios-ipa\ios\ChatFlow-0.4.7-build2172-enterprise-resign-candidate.ipa`，60,809,306 字节，SHA256 `4ee3a233e66b0349666e43adae7a016ead3e2bef2dfd8e45c9840cda3c924767`；本地复制后再次核对 SHA。当前是 Apple Distribution 候选签名，需用户企业重签；CI 验签不代表回签后的最终包已验签。用户回传前不发布 iOS 版本设置、manifest、安装页或弹窗。
