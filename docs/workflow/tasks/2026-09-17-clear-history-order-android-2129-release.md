# 任务记录：清空聊天记录会话位置修复 + Android 0.3.94/2129 发布 + GitHub 推送

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-17 三项要求（原话）：①修复「清空聊天记录」后该消息会话房间位于
  「消息」页列表的位置不变（当前会自动排到列表末端，不符合操作直觉）；②推送 Android 最新版本的更新弹窗；
  ③推送到 GitHub 仓库。边界：不改红包分配/领取/退款公式、E2EE、RBAC、TOTP、审批、幂等、对账、审计检查；
  不轮换 APK 签名身份；不改 iOS 更新行与 manifest；`min_supported_build` 不提高（不做强制升级）。
- 关联计划/ADR：沿用 [Android 重建 runbook](../../runbooks/android-apk-rebuild.md) 与
  [移动交付流程](../../runbooks/mobile-delivery-workflow.md)、[admin 生产流程](../../runbooks/admin-production-workflow.md)；
  本次无新 ADR（第 1 项为缺陷修复，第 2 项为发行操作）。
- 当前状态：**完成**（① 修复并回归；② 0.3.94/2129 已构建、上传、上线并发布更新弹窗、公网双侧验证通过；
  ③ 已推送 `origin/main`）。真机安装与弹窗实弹由用户验收。
- 负责人、工作树、文件所有权、源码 commit：主工作树 `D:\pythonProject\outsource\StarChat`（`main`）。
  拥有：`apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`、
  `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart`、
  `apps/mobile_flutter/test/features/matrix/local_history_clear_test.dart`、
  `apps/mobile_flutter/pubspec.yaml`、`apps/mobile_flutter/lib/core/app_config.dart`、
  `docs/verification/artifacts/2026-09-17/release-2129/**`、`docs/verification/2026-09-17-clear-history-order-android-2129-release.md`。
  源码 commit：`175b3e6e`（修复）、`c73c12fb`（版本冻结 + 推送基线）。
- 最后更新时间（含时区）：2026-09-17 16:3x +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收 ID：用户在 Mi 6 安装
  `ChatFlow-0.3.94-build2129-arm64.apk` 并确认 A1（清空后会话不移动）与 A4（弹窗出现、可稍后再说）；
  无阻断项。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 「清空聊天记录」后该会话在「消息」页列表的位置不变（不掉到末尾） | 新增顶层 `conversationSortAnchor(room)`（`lastEvent?.originServerTs ?? lastActivityAt ?? epoch0`）；`MatrixConversationRoomSnapshot` 新增可选 `lastActivityAt` 并由 `_snapshotRoom` 从事件时间戳填充；`_snapshotRoom` 排序锚点改用它 | `local_history_clear_test.dart` 新增用例「…位置不变（不掉到末尾）」；变异探针（忽略 `lastActivityAt`）→ 实得 1970-01-01 转红，复原转绿；定向 8 通过 / 0 失败（`clear-history-order-regression.txt`）；`flutter analyze` 无问题 | 已随 0.3.94/2129 发布 | 待用户真机 |
| A2 | Android 更新弹窗推送到线上 | 设置 inspect → apply（trace `android-release-0.3.94-2129-20260917`，5 条审计，min `3` 沿用，iOS 行未改） | `settings-publish-inspect.log` / `settings-publish-apply.log`（`PUBLISH_PASS`）；真实 HTTP 投影 `live-projection-2129.log`（`LIVE_HTTP_PROJECTION_OK`） | **已上线** | 待用户真机确认弹窗 |
| A3 | 新 APK 可公网下载且与本地构建一致 | 16MiB 分块上传 → 服务端合并 SHA 门 → `install -m 0644` 不可变文件 → `latest-arm64.apk` 原子切换 | 服务器+工作站双侧 200/206 + MIME；**公网整包 SHA256 = 本地构建包**；旧包 2127 仍 200（`public-verify-server.log` / `public-verify-workstation.log`） | **已上线** | — |
| A4 | 更新弹窗对现网 Android 用户可见（可关闭） | `latest_version 0.3.94 > 0.3.93` 且 `platform` 标记为 `android` | 带真实会话 token 的 HTTP GET 返回 `configured=true` / `platform=android` / `2129` | **已上线** | 待用户真机 |
| A5 | 代码推送到 GitHub 仓库 | `git push origin main` | `5d43ce34..c73c12fb main -> main`（退出码 0）；`origin/main...main` = `0 0` | — | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android 正式版 | **0.3.94 / 2129** | `c73c12fb` | `com.liuhetong.mobile`，固定身份 `75b31c66…ba61fff`（v2+v3） | `/opt/starchat/frontend/downloads/ChatFlow-0.3.94-build2129-arm64.apk`，**79,408,158 字节**，SHA256 `B3B70C665E524CE95807EC0D80CA7BF0F211B242176285ED2D8F67CCABB4BF92` | 已上线；`https://www.liuhetong888.com/downloads/ChatFlow-0.3.94-build2129-arm64.apk`；`latest-arm64.apk` 已切至 2129 |
| Android 回退包 | 0.3.93 / 2127 | `d30bd051` | 同上身份 | `ChatFlow-0.3.93-build2127-arm64.apk`（原位保留，200） | 回退路径 |
| 业务 API | `starchat-business-api:redpacket-fee-20260917`（digest `sha256:48948fb7…`），healthy | 当日手续费部署，本次未改 | — | 本次仅写 app_update 设置 | 15 分钟窗口无 error/exception/traceback |
| 业务 worker | `starchat-business-worker:redpacket-fee-20260917`，healthy | 同上 | — | — | 未重启 |
| iOS | 未构建；更新行保持 0.3.92/2120 | — | — | `downloads/ios/manifest.plist` 200（未改） | — |
| GitHub | `origin/main` = `c73c12fb01ef89e4ed2b3be976e22689d350183b` | — | — | `https://github.com/SuperJJ2333/StarChat.git` | 推送 `5d43ce34..c73c12fb` |

测试记录：

- 修复定向回归：`local_history_clear_test.dart` + `conversation_preferences_test.dart` → **8 通过 / 0 失败（退出码 0）**，
  日志 `artifacts/2026-09-17/release-2129/clear-history-order-regression.txt`（工具链：Flutter 快照经
  `dart.exe --packages=… package_config.json flutter_tools.snapshot test`）。
- 冻结候选全量 `flutter test`：**2852 通过 / 0 失败（退出码 0）**，
  日志 `artifacts/2026-09-17/release-2129/android/flutter-full-candidate-2129.txt`；`flutter analyze` `No issues found!`。
- 版本契约：`tests/mobile/test_app_build_contract.py` 2 通过。
- 构建门禁：`verify_android_release.py`（源/最终）、aapt 身份、apksigner v2+v3、zipalign `-c -P 16 4`、
  `verify_rebuild.py` 语义核对（类数 25345/25345、原生/资产 338 项零变化、`manifest.diff` 0 字节）。
- 发布后验证：真实 HTTP 投影（401 未授权 / 200 带 token）、服务器+工作站双侧公网 200/206 + MIME、
  公网整包 SHA256 与本地一致、`/api/v1/health/{live,ready}` 200。
- 全仓门禁 `pwsh -NoProfile -File scripts/verify.ps1`（HEAD `ebd56b36`，退出码 0）：**`Verification: PASS`**——
  Repository/Deployment policy、TemplateTools、Infra render 143、Getui bridge 28、Matrix Bot 9、
  **Business API and Worker 1933 通过 / 58 跳过 / 0 失败**、Flutter boundary 70、
  UI contract PASS（30 组件 / 369 页面）、Business API import、AST parse 219、Alembic、OpenAPI、Compose render
  全部通过；日志 `artifacts/2026-09-17/release-2129/verify-full-repo-2129.txt`。
- 未执行：iOS 构建；2129 真机安装与弹窗实弹（均由用户验收）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| A1 根因定位 → 红绿 → 变异探针 | 16:0x | 16:1x | 主动 | — | 8 通过；`175b3e6e` | — |
| 版本冻结 + 全量候选门禁 | 16:1x | 16:2x | 工具等待（全量 2852 用例） | 与文档并行 | 2852 通过；`c73c12fb` | — |
| 构建（Flutter → Apktool → zipalign → 签名 → 门禁） | 16:2x | 16:4x | 工具等待（Gradle 147.6s + 重建/核对） | — | 退出码 0；SHA `B3B70C66…` | — |
| 分块上传 + 合并/安装/切换 | 16:4x | 16:5x | 外部等待（跳板传输 79MB） | — | SHA 门通过 | — |
| 更新弹窗 inspect/apply + 真实 HTTP 投影 | 16:5x | 17:0x | 主动 | — | `PUBLISH_PASS` | — |
| 公网双侧验证 + GitHub 推送 | 17:0x | 17:1x | 外部等待（隧道路由 + 79MB 公网下载） | 与文档并行 | 双侧通过；推送退出码 0 | — |

总墙钟：约 1 小时（未逐段精确计时，不估成精确值）。返工：一次——公网 `/health/live` 与 `www` 主机
`/api/...` 探测得到 `200 text/html`（SPA 回落）而非 API 响应，定位后改用正确路径
`/api/v1/health/*` 与客户端实际主机 `https://liuhetong888.com` 复测；该假阳性已记入验证记录第 2.6 节。

## 交接与回退

- 已确认根因/已排除假设：清空历史后 `lastEvent` 为 `null` → 排序锚点落到 epoch0 是唯一根因；
  已排除「清空截止时间写错」「会话被误删」两类假设（`historyClearedThrough` 与原「删除该聊天」语义
  在 2026-09-16 任务中已分离，本次未改）。
- 行为变更（需知悉）：无用户可见行为变更（仅修复排序位置）；`MatrixConversationRoomSnapshot` 新增可选字段，
  默认 `null`，对既有调用方向后兼容。
- 待办及验收失败项：A1/A2/A4 待用户真机；无失败项。
- 已发布与仅候选的区别：**本次全部为已发布**（APK 已上线、弹窗已推送、`latest-arm64.apk` 已切换；
  文档 commit 为本地/GitHub 变更）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：
  设置备份 `/opt/starchat/releases/android-0394-2129-20260917/backup/settings-before-2129.json`（0600，
  sha256 `838f2293…`）；回退见验证记录第 2.8 节（`publish_settings_2129.py rollback` + `ln -sfn` 指回 2127）。
  本次未改容器镜像/数据库，无镜像或迁移回退需求。
- 运行中 CI/命令/自己创建的隧道（无凭据）：用于公网验证的跳板 SOCKS 隧道（`127.0.0.1:18944`）**已在验证后关闭**；
  无其他常驻进程。
- 下次恢复先检查的事实：① 线上 `app_latest_build` 是否仍为 `2129`、`apk_url` 是否指向 2129 版本文件；
  ② `latest-arm64.apk` 是否仍指向 `ChatFlow-0.3.94-build2129-arm64.apk`；
  ③ `matrix_home_page.dart` 是否仍用 `conversationSortAnchor(room)` 作为 `lastActivity`
  （不得退回只用 `lastEvent?.originServerTs`）；④ `MatrixConversationRoomSnapshot.lastActivityAt` 是否仍由
  `_snapshotRoom` 填充；⑤ `origin/main` 是否已包含 `c73c12fb`。
