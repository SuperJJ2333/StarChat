# 2026-09-18 Android 0.3.96/2134 发布 + iOS 0.3.96/2134 企业签名交接

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令（本会话）——
  “推送最新版本的 Android 更新弹窗，并提供 iOS 更新包给我签名，然后我返回 ipa 给你进行分发”。
  用户选定：版本 **0.3.96 + 2134**、包含自 2132 之后 main 上的**全部客户端改动**、更新弹窗**不强制**。
  禁止范围（沿用既有约定）：不改签名身份、不改 E2EE/Matrix 协议、不做破坏性迁移、不安装 iOS 包（企业签名由用户完成）。
- 关联计划/ADR：[Android APK 固定打包流程](../../runbooks/android-apk-rebuild.md)、
  [移动应用发布部署](../../runbooks/app-release-deployment.md)、
  [0.3.95/2132 发布记录](../../verification/2026-09-17-android-0395-2132-release.md)、
  [iOS 2132 企业重签交接](../../verification/2026-09-17-ios-0395-2132-enterprise-resign-handover.md)。
- 当前状态：**Android 0.3.96/2134 已上线**（APK + 更新弹窗 + 公网校验）；
  **iOS 0.3.96/2134 候选 IPA 已从 CI 取回并核验，等待用户企业签名后回传分发**。
- 负责人、工作树、文件所有权、源码 commit：本地工作树 `D:\pythonProject\outsource\StarChat`，分支 `main`。
  候选冻结 **`71971746`**（含 `04cc1d80` Matrix 初始化串行化修复）；版本递增提交 `a4b53386`。
  本轮新增：`docs/verification/2026-09-18-android-0396-2134-release.md`、
  `docs/verification/2026-09-18-ios-0396-2134-enterprise-resign-handover.md`、
  `docs/verification/artifacts/2026-09-18/release-2134/**`、`docs/verification/artifacts/2026-09-18/ios-2134/**`、
  以及 `tests/mobile/test_ios_simulator_ci.py` 的契约修正（修复被合并改动打红的 CI）。
- 最后更新时间（含时区）：2026-09-18（Asia/Hong_Kong）。
- 下一条具体操作、必要输入、阻断的验收 ID：**等用户回传企业签名后的 IPA** → 校验（Bundle ID/版本/entitlements/SHA）
  → 上传 `/opt/starchat/frontend/downloads/ios/` → 更新 `manifest.plist` → 更新 `app_ios_*` 设置（不动 Android 行）
  → 公网校验。当前**无阻断项**（iOS 分发按约定由用户签名解锁）。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| R1 | 版本号必须高于线上 2132，否则客户端收不到弹窗 | `scripts/bump_version.ps1 -Version 0.3.96+2134`（`a4b53386`） | 版本契约 `2 passed`；aapt：`versionCode=2134 / versionName=0.3.96` | 已上线 | — |
| R2 | 冻结候选上全量门禁通过 | 无（发布流程） | `flutter analyze` No issues；`flutter test` **+3173 全通过**；`pytest tests/mobile` **70 passed**；CI `android-ci` run **35356378136** @ `71971746` **success** | 已上线 | — |
| R3 | 修复被并发改动打红的 CI 契约 | `tests/mobile/test_ios_simulator_ci.py` 改为断言“每次尝试日志保留 + `if: always()` 上传目录” | 失败 run `35352090250`（`36955d78`）→ 修正后 **success** | 已上线 | — |
| R4 | 固定流程出包且身份不变 | `build-android.ps1`（两阶段：release 构建 → 必要时剥离 dev-only 插件注册 → `--no-pub` 重建） | apksigner v2/v3 ✓，证书 `75b31c66…ba61fff`；zipalign 通过；`verify_android_release.py` 源包+终包均 arm64-v8a | 已上线 | — |
| R5 | 重建语义零漂移 | Apktool 2.12.1 解包/重建 + `verify_rebuild.py` | 类数 **25346/25346**、`changed_smali_classes: []`、原生资产 **338 零变化**、`manifest_semantics_identical: true`、`manifest.diff` 0 字节、release 注册表无 `integration_test` | 已上线 | — |
| R6 | 交付包唯一且可回溯 | 交付 `final.apk` = `ChatFlow-0.3.96-build2134-arm64.apk` | 79,997,982 字节，SHA256 `7628FBD0…626B` | 已上线 | — |
| R7 | 上传/合并/切换有 SHA 门且旧包保留 | `upload-apk.ps1`（分片+远端尺寸核对）→ `bash publish-apk.sh`（合并 SHA 门 + `install` + `ln -sfn`） | `merged_sha == expected`；`latest-arm64.apk` → 2134；2132 原位保留（sha `35ca0962…`） | 已上线 | — |
| R8 | 更新弹窗发布且不强制、不动 iOS 行 | `publish_settings_2134.py` inspect → apply | `PUBLISH_PASS`；`audit_count=5`；`min_supported_build` 仍 3；`app_ios_*` 零改动；Android 投影 `0.3.96/2134` | 已上线 | — |
| R9 | 公网可下载且鉴权边界不变 | 公网 HEAD/分段 + 未授权接口探测 | 别名 HEAD `200 octet-stream`；版本化 URL `206`；文件与别名 SHA 一致；`/app-updates/latest` 未授权 `401` | 已上线 | 未用真实用户 token 做授权端到端 |
| R10 | iOS 候选包与 Android 同源、可重签 | CI `ios-0353.yml` run **35355808244** @ `04cc1d80`（与候选差异仅文档） | 见 iOS 交接记录（Info.plist/版本/cryptid/SHA） | **待签名** | 用户签名后回传 |
| R11 | 真机验收 | 无（按分工由用户执行） | — | — | **未完成**（不阻塞发布） |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android 正式版 | `0.3.96 / 2134`（`com.liuhetong.mobile`，arm64-v8a） | `71971746` | 固定身份签名（`75b31c66…ba61fff`） | 服务器 `/opt/starchat/frontend/downloads/ChatFlow-0.3.96-build2134-arm64.apk`；本地产物 `docs/verification/artifacts/2026-09-18/release-2134/android/final.apk`；SHA256 `7628FBD095277E3369313AEE877B76F43C7741E07754AF9F587BAF16CD28626B` | 2026-09-18 14:41Z 切换；弹窗 trace `android-release-0.3.96-2134-20260918`（5 条审计） |
| Android 回退包 | `0.3.95 / 2132` | `9fa2c963` | 同上 | `ChatFlow-0.3.95-build2132-arm64.apk`，SHA256 `35CA0962…4633` | 原位保留 |
| iOS 候选（待企业签名） | `0.3.96 / 2134` | `04cc1d80` | CI `ChatFlow-iOS-signed`（占位签名，可重签） | `docs/verification/artifacts/2026-09-18/ios-2134/`（artifact id `10551264894`） | CI run `35355808244` success；artifact 有效期至 2026-10-02 |

- 命令与退出码：
  - `flutter analyze` → No issues found（9.1s）
  - `flutter test --timeout 120s` → `+3173: All tests passed!`
  - `pytest tests/mobile/test_app_build_contract.py -q` → 2 passed
  - `pytest tests/mobile -q` → 70 passed
  - `build-android.ps1` → `BUILD_2134_OK`
  - `upload-apk.ps1` → `CHUNKS_UPLOADED`（5 片尺寸逐一核对）
  - `bash publish-apk.sh 7628FB…` → SHA gate passed + `===DONE===`
  - `publish_settings_2134.py inspect/apply` → `PUBLISH_PASS`（5 条审计）
- 未执行项：Android 正式包真机安装、iOS 企业签名与分发、iOS 真机验收。
- 复用依据：本轮代码改动（含并发会话的客户端修复）导致既有门禁结论**不再复用**，全量重跑；
  `scripts/verify.ps1` 未重跑（其服务端/仓库部分在 `27a09910` 已 PASS，其后仅文档与 iOS 配置变动），
  但移动侧等价门禁（analyze + 全量 flutter test + tests/mobile + CI android-ci）已在冻结候选上重跑。

## 阶段计时

| 阶段 | 开始 | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 前置核查（工具链/线上版本/更新弹窗现状） | 22:40 | 22:47 | 主动（读 runbook + 复用 2132 脚本） | — | 线上 `0.3.95/2132`、iOS `0.3.92/2120` | 版本递增 |
| 版本递增 + 门禁 | 22:47 | 23:00 | 主动 + 工具等待（flutter test ~13 min） | 与 iOS CI 并行（push 触发） | analyze/3173 test/contract/70 mobile | 出包 |
| **返工：release 构建 dev-only 插件冲突** | 23:00 | 23:25 | 主动排查（4 次失败构建 + Flutter 工具源码比对） | — | 定位 `flutter assemble` 未过滤 dev 依赖 vs AGP 不给 release 类路径；脚本化剥离 | 出包 |
| 完整出包 + 语义核对 | 23:25 | 23:33 | 工具等待（Apktool/flutter ~8 min） | — | `BUILD_2134_OK` | 上传 |
| 上传 + 发布 + 弹窗 + 公网校验 | 23:33 | 23:45 | 工具等待（80 MB 分片上传） | — | `PUBLISH_PASS`、SHA 一致 | iOS 交接 |
| iOS 候选取回 | 23:45 | 进行中 | 外部等待（GitHub artifact 直连限速 ~43 KB/s） | — | 59,919,267 字节，digest 校验 | 交接文档 |

总墙钟：约 1 小时（不含 iOS 下载等待）。返工：2 次（CI 契约失效 1 次、release 构建 dev-only 插件冲突 1 次），
均已定位根因并脚本化/加断言，未使用绕过手段。

## 交接与回退

- 已确认根因：
  - **CI 变红**：并发会话改了 iOS 工作流但未同步 `tests/mobile/test_ios_simulator_ci.py` 的日志名契约；
    修正为“每次尝试日志保留 + 总是上传目录”，并断言构建命令与无插件排除。
  - **release 构建失败**：Flutter 3.44.9 下 `flutter assemble` 会在 release 构建中把 dev 依赖
    （`integration_test`）写回插件注册表，而 AGP 按设计不把 dev 依赖放进 release 编译类路径；
    已用“剥离唯一 dev 注册块 + `--no-pub` 重建 + 反向断言”消除，且与 2132 基线一致（其反编译亦无该插件）。
- 已排除假设：不是签名身份问题（证书指纹一致）；不是 apktool/zipalign 问题（门禁全过、类数与资产零漂移）；
  不是版本号写错（aapt 与契约双重确认）。
- 待办及验收失败项：无失败项。iOS 分发待用户签名回传；Android 真机验收待用户执行。
- 已发布与仅候选的区别：Android **已发布**（APK 上线 + 弹窗生效）；iOS **仅候选**（未上传、未改设置）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：
  - 回退设置：`publish_settings_2134.py rollback`；回退文件：`ln -sfn ChatFlow-0.3.95-build2132-arm64.apk latest-arm64.apk`；
  - 漂移检查：`sha256sum /opt/starchat/frontend/downloads/ChatFlow-0.3.96-build2134-arm64.apk` 应等于 `7628FBD0…`；
  - 可重试阶段：分片上传可重跑（脚本先清空远端分片目录）；弹窗 apply 幂等（`current == desired` 时直接断言通过）。
- 运行中 CI/命令/自己创建的隧道（无凭据）：无；SSH 经既有跳板；未使用用户账号凭据。
- 下次恢复先检查的事实：① 用户是否已回传企业签名 IPA（校验方法见 iOS 交接记录第 3 节）；
  ② 线上 Android 版本/弹窗是否为 `0.3.96/2134`；③ iOS 行是否仍为 `0.3.92/2120`（分发前不得提前改动）。
