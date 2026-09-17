# 2026-09-17 「清空聊天记录」会话位置不变修复 + Android 0.3.94/2129 发布 + GitHub 推送

用户三项要求：①修复「清空聊天记录」后该会话在「消息」页列表中的位置不变（当前会掉到末尾）；
②推送 Android 最新版本的更新弹窗；③推送到 GitHub 仓库。

发布参数（沿用用户既有选择）：版本 **0.3.94 + 2129**、更新说明用已批准草案、**不强制更新**。

## 1. 第 1 项：清空聊天记录后会话位置不变

**根因**：`MatrixHomePage._snapshotRoom` 的排序锚点取 `room.lastEvent?.originServerTs ?? epoch0`。
「清空聊天记录」写的是本机 `historyClearedThrough`，被清空的历史事件随后由 `isEventHidden` 隐藏，
于是该房间的 `lastEvent` 变为 `null` → 锚点落到 `DateTime.fromMillisecondsSinceEpoch(0)`（1970-01-01）
→ 在 `orderConversations` 的降序排序里掉到末尾。清空历史不应改变会话的活跃时间语义。

**修复**（最小改动，不动 E2EE/隐藏语义）：

- `matrix_e2ee_client.dart`：`MatrixConversationRoomSnapshot` 新增可选 `final DateTime? lastActivityAt;`
  （公开工厂与 `_trusted` 构造均默认 `null`，既有测试调用点无需改动）；
  `_snapshotRoom` 用 `event?.originServerTs ?? originalEvent?.originServerTs` 填充——它取自事件时间戳本身，
  与「是否被本机隐藏」解耦。
- `matrix_home_page.dart`：新增顶层函数
  `DateTime conversationSortAnchor(MatrixConversationRoomSnapshot room) => room.lastEvent?.originServerTs ?? room.lastActivityAt ?? DateTime.fromMillisecondsSinceEpoch(0);`，
  `_snapshotRoom` 的 `lastActivity` 改用该锚点；列表排序（`orderConversations`）与置顶语义均未改。

**红绿证据**：`test/features/matrix/local_history_clear_test.dart` 新增用例
「清空聊天记录后该会话在消息列表中的位置不变（不掉到末尾）」——构造两个房间
（`!newest:test` 最后事件 2026-09-03 且已清空、`!older:test` 2026-09-02 未清空），
断言 `snapshot.lastActivityAt == newestEvent.originServerTs`，并用
`orderConversations([...conversationSortAnchor(room)...])` 断言清空后顺序不变。

**变异探针**：把锚点改回忽略 `lastActivityAt`（返回 epoch0）→ 断言实得 `1970-01-01`、用例转红；
复原后转绿。证明该用例确实锁住本次缺陷，而不是恒真。

| 检查 | 结果 |
| --- | --- |
| 定向回归 `local_history_clear_test.dart` + `conversation_preferences_test.dart` | **8 通过 / 0 失败（退出码 0）**，日志 `artifacts/2026-09-17/release-2129/clear-history-order-regression.txt` |
| `flutter analyze` | `No issues found!` |
| 全仓门禁 `scripts/verify.ps1`（HEAD `ebd56b36`） | **`Verification: PASS`（退出码 0）**：Business API and Worker 1933 通过 / 58 跳过、Flutter boundary 70、UI contract PASS（30 组件 / 369 页面）、AST parse 219、Alembic / OpenAPI / Compose render 全通过；日志 `artifacts/2026-09-17/release-2129/verify-full-repo-2129.txt` |
| 源码 commit | `175b3e6e`（`fix(chat): keep the conversation in place after 清空聊天记录`） |

## 2. 第 2 项：Android 0.3.94/2129 发布

### 2.1 候选冻结

- `pubspec.yaml` → `0.3.94+2129`；`lib/core/app_config.dart` → `appVersionName='0.3.94'` / `appBuildNumber=2129`
  （`tests/mobile/test_app_build_contract.py` 2 通过）。
- 候选 commit **`c73c12fb`**（`release: freeze 0.3.94+2129 Android candidate`），工作树干净。
- 全量 `flutter test`（冻结候选）：**2852 通过 / 0 失败（退出码 0）**，
  日志 `artifacts/2026-09-17/release-2129/android/flutter-full-candidate-2129.txt`。
- **版本选择理由**：2129 > 线上已发布 2127，也 > Mi 6 已安装的 debug 2128，避免 versionCode 降级被拒装。

### 2.2 构建（固定流程，未轮换签名身份）

脚本 `artifacts/2026-09-17/release-2129/build-android.ps1`（退出码 0）：
Flutter `build apk --release --flavor standard --target-platform android-arm64` + 三项 HTTPS dart-define
→ Apktool 2.12.1 重建 → zipalign 36.0.0 `-P 16 -f 4` → 固定身份 `75b31c66…ba61fff` 签名。

| 门禁 | 结果 |
| --- | --- |
| 源包发行门禁 `verify_android_release.py` | `abis=["arm64-v8a"]`，79,060,748 字节，sha256 `1828fe18…0587a9` |
| 最终包发行门禁 | `abis=["arm64-v8a"]`，**79,408,158 字节**，sha256 `b3b70c66…cabb4bf92` |
| aapt 身份 | `com.liuhetong.mobile` versionCode **2129** / versionName **0.3.94** / native-code `arm64-v8a`，targetSdk 36 |
| apksigner | v2 ✓ v3 ✓；`Signer #1 certificate SHA-256: 75b31c66…ba61fff` |
| zipalign `-c -P 16 4` | `Verification successful`（签名后复查，退出码 0；日志 `zipalign-check.log`） |
| 语义重建核对 | 类数 25345/25345、`changed_smali_classes=[]`、原生/资产 338 项零变化、`manifest_semantics_identical=true`、`manifest.diff` 0 字节 |

**最终交付 SHA256：`B3B70C665E524CE95807EC0D80CA7BF0F211B242176285ED2D8F67CCABB4BF92`（79,408,158 字节）。**

> 说明：2127 与 2129 最终包的字节数恰好相同（均为 79,408,158）。已单独核对差异证据：
> `lib/arm64-v8a/libapp.so` 长度同为 15,795,088 但 SHA256 不同
> （2127 `ee74f2b4…42ff1`、2129 `8711e223…cfebbf`），即 AOT 代码确已更新（Dart 快照分节对齐使总长不变），
> 不存在「构建出新包但内容未变」的情况。

### 2.3 上传与安装

- 16 MiB 分块（part-00…part-04）经跳板顺序上传，逐块核对远端字节数（16777216×4 + 12299294），
  日志 `apk-upload.log`。
- 服务端 `cat` 合并 → **SHA256 门**比对本地基线一致（`merged_sha=B3B70C66…`）→
  `install -m 0644` 为不可变版本文件
  `/opt/starchat/frontend/downloads/ChatFlow-0.3.94-build2129-arm64.apk`；
  2127 及更早包原位保留（回退路径）。日志 `apk-merge-install.log`。
- `latest-arm64.apk` 以 `ln -sfn` + `mv -T` **原子切换**至 2129（`latest-arm64.apk -> ChatFlow-0.3.94-build2129-arm64.apk`，
  哈希与版本文件一致）。

### 2.4 更新弹窗发布（SettingService inspect → apply）

trace `android-release-0.3.94-2129-20260917`，actor `ops-codex-android-release`，
脚本 `publish_settings_2129.py`。preflight 备份先留容器 `/tmp`，再 `docker cp` 到宿主机私有目录
`/opt/starchat/releases/android-0394-2129-20260917/backup/settings-before-2129.json`（**0600**，
sha256 `838f22939d82d48aed210b05f8b913e46bee8f2a87e7eeec8a1762ff29d1af24`）。

| 键 | 发布前 | 发布值 |
| --- | --- | --- |
| `app_latest_version` | `0.3.93` | **`0.3.94`** |
| `app_latest_build` | `2127` | **`2129`** |
| `app_min_supported_build` | `3` | **`3`（沿用，无强制更新）** |
| `app_update_notes` | （0.3.93 文案） | `v0.3.94 更新\n发红包新增 0.5% 手续费（最低 0.01 点钻）并展示实扣合计；修复清空聊天记录后会话跑到列表末尾；钱包绑定/刷新与充值提现界面优化。`（80 字符，≤255） |
| `app_apk_url` | `…/ChatFlow-0.3.93-build2127-arm64.apk` | **`https://www.liuhetong888.com/downloads/ChatFlow-0.3.94-build2129-arm64.apk`** |

- apply 断言：设置读回等于发布值、**iOS 行逐键不变**、`min_supported_build` 未变、
  审计行 **5**、Android 投影 `platform=="android"` 且 `latest_build==2129`、
  iOS 投影仍 `2120` → 结果 **`PUBLISH_PASS`**（日志 `settings-publish-apply.log`）。

### 2.5 真实 HTTP 投影验证（不冒充登录客户端）

`verify_live_projection_2129.py` 在容器内铸造**短期超管会话 token**，对真实端点发起 HTTP GET
（区别于 2.4 的进程内投影读回）：

| 目标 | 未授权 | 带 token |
| --- | --- | --- |
| `http://127.0.0.1:8082/api/v1/app-updates/latest?platform=android` | **401** `AUTH_REQUIRED` | **200**，`platform=android` / `configured=true` / `0.3.94` / `2129` / min `3` |
| `https://liuhetong888.com/api/v1/app-updates/latest?platform=android`（客户端实际主机） | **401** `AUTH_REQUIRED` | **200**，同上 |

两侧均输出 `LIVE_HTTP_PROJECTION_OK`，日志 `live-projection-2129.log`。

### 2.6 公网验证（服务器 + 工作站 jumper SOCKS 双侧，TLS 校验保留）

服务器侧（`public-verify-server.log`）：

| 检查 | 结果 |
| --- | --- |
| 版本化包 `ChatFlow-0.3.94-build2129-arm64.apk` | 200 / `application/octet-stream` / 79,408,158 |
| Range 探测 | 206 / 1024 |
| `latest-arm64.apk` | 200（=2129）+ 206 |
| 旧包 2127（回退路径） | 200 / 79,408,158 |
| 公网整包下载 SHA256 | `b3b70c66…cabb4bf92`，与本地构建包**一致** |

工作站侧（`socks5h://127.0.0.1:18944` 经跳板，`public-verify-workstation.log`）：

| 检查 | 结果 |
| --- | --- |
| 版本化包 | 200 / `application/octet-stream` / 79,408,158 |
| Range 探测 | 206 / 1024 |
| `latest-arm64.apk` | 200（=2129）+ 206 |
| 旧包 2127 | 200 / 79,408,158 |
| 下载页 `download.html` | 200 `text/html` |
| iOS 清单 `downloads/ios/manifest.plist` | 200 `application/xml`（未改动） |
| **公网完整下载 SHA256** | **`B3B70C665E524CE95807EC0D80CA7BF0F211B242176285ED2D8F67CCABB4BF92`，与本地构建包完全一致** |

健康检查（正确路径为 `/api/v1/health/*`，日志 `health-check.log`）：
容器内 `ready=200` / `live=200`（`application/json`），公网 non-www 主机 `pub_ready=200` / `pub_live=200`。

**记录下一处此前的假阳性来源**：`www.liuhetong888.com` 对未知路径回落到 SPA 静态页，
因此对 `www` 探测 `/api/v1/...` 或 `/health/...` 会得到 `200 text/html`（811 字节），
**不能当作 API 存活证据**。客户端 release 包的 dart-define 使用 **non-www** `https://liuhetong888.com`，
该主机正确代理 API（未授权 401、健康 200 JSON），故更新弹窗链路不受影响。

### 2.7 未改动 / 限制

- `min_supported_build` 保持 `3`：本次为**可关闭**的正常更新弹窗，不构成强制升级。
- 现有 0.3.93/2127 客户端：`latest_version 0.3.94 > 0.3.93` → 弹窗出现，可「稍后再说」。
- iOS 行（0.3.92/2120）与 iOS manifest 均未改动；未构建 iOS。
- **未做真机安装/弹窗实弹验收**：本次为服务端 + 包发布，用户可在真机确认。
- 本次**未改任何 API 代码、未迁移数据库、未重建容器**（2.4 只写 app_update 设置）。

### 2.8 回退

1. 更新弹窗：`publish_settings_2129.py rollback`（恢复 0.3.93/2127，写 `<trace>-rollback` 审计）。
2. APK 别名：`ln -sfn ChatFlow-0.3.93-build2127-arm64.apk latest-arm64.apk`（2127 原位保留）。
3. 无需镜像/迁移回退（本次未触碰 API 与数据库）。

## 3. 第 3 项：GitHub 推送

- `git push origin main` → **`5d43ce34..c73c12fb main -> main`（退出码 0）**，远端
  `https://github.com/SuperJJ2333/StarChat.git`，凭据由 `credential.helper=manager` 提供；
  未使用 `-k`、未放宽 TLS/主机校验、未改写历史。
- 推送后核对：`git rev-list --left-right --count origin/main...main` → `0  0`，
  `origin/main == main == c73c12fb01ef89e4ed2b3be976e22689d350183b`。
- 说明：本验证记录在推送之后产生，随后的文档 commit 会再次推送，使仓库包含发布证据。

## 4. 发布后生产状态（2026-09-17 08:1x UTC）

| 项 | 值 |
| --- | --- |
| 业务 API 容器 | `starchat-business-api-1`，镜像 `starchat-business-api:redpacket-fee-20260917`，digest `sha256:48948fb7…`，healthy |
| 业务 worker 容器 | `starchat-business-worker-1`，镜像 `starchat-business-worker:redpacket-fee-20260917`，healthy |
| 容器重启 | 无（发布设置未重建容器；API 仍为当日 15:53 +08 手续费部署的同一实例） |
| API 日志 | 切换后 15 分钟窗口 `error|exception|traceback|critical` **零命中**（`post-publish-audit.log`） |
| Android 已发布包 | `0.3.94` / build `2129`，`ChatFlow-0.3.94-build2129-arm64.apk` |
| `latest-arm64.apk` | → 2129 |
| Android 更新弹窗 | `0.3.94` / `2129`，min_supported_build `3` |
| iOS 更新行 | `0.3.92` / `2120`（未改） |
| 回退包 | `ChatFlow-0.3.93-build2127-arm64.apk` 原位保留 |

## 5. 剩余风险与待办

- 红包手续费在客户端（红包弹层与 PIN 弹层）的**展示**仅存在于本 0.3.94 及以后客户端；
  线上 ≤0.3.93/2127 客户端仍只按 `total` 校验余额，余额处于 `[total, total+fee)` 时会收到
  带合计说明的 422——本 0.3.94 发布正是该显示/扣费口径不一致的修复路径，用户升级后消失。
- 未做 2129 的真机安装与「弹窗实际弹出」验收（用户可自行确认）。
- 既有、非本次引入：worker 日志存在 `outbox dead-letter: 2 events have no registered consumer`
  （ADR-0071 r2 曾记录 3），属运维侧 replay 复核事项。
