# Android 提现报价策略兼容修复任务记录

## 恢复入口

- 目标、用户授权来源及边界：修复发行 Android v0.4.21+2190 点击提现后出现 `Invalid manual wallet response`；用户批准客户端兼容方案、书面规格，并要求以 Android Debug v0.4.23+2192 为源码基础，先交付模拟器 Debug，再发布正式 ARM64 更新。用户已批准[修订计划](../../superpowers/plans/2026-09-29-android-withdrawal-quote-policy-compatibility.md)实施及发布。只接受服务端现有的 `OWNER_MANUAL_V1`、`SUPPORT_MANUAL_V1` 报价策略；资金权限、幂等、服务端与 iOS 行为不在改动范围。正式发布须等待另一任务的 API v4b 安全发布并通过现网门禁。
- 关联计划/ADR：[书面规格](../../superpowers/specs/2026-09-29-android-withdrawal-quote-policy-compatibility-design.md)、[修订计划](../../superpowers/plans/2026-09-29-android-withdrawal-quote-policy-compatibility.md)、[ADR-0081](../../adr/0081-support-order-settlement-and-staff-activation.md)。
- 当前状态：2192 字节基线与 Task 2 客户端测试先行修复完成；`0.4.24+2193` 源码 `dae8ec6301e4c22d09721c6f54ccc9cc90bc6f3d`。Task 3 源码审查、钱包定向、analyze、移动边界、UI 契约、OpenAPI 和迁移 head 检查已完成；短盘符全量 Flutter **5132 通过/9 跳过、exit 0**。长路径首轮失败及整库脚本因无 `.env` exit 1 均保留真实记录。Task 4 固定签名 x86_64 Debug 已构建并保留数据覆盖安装 `emulator-5556`，设备包 SHA 与本次包一致；Task 5 正式 ARM64 候选另树准备中，本任务尚未发布正式更新。
- 负责人、工作树、文件所有权、源码 commit：本任务 `codex/withdrawal-quote-policy-20260929`，`C:/Users/Administrator/.codex/worktrees/withdrawal-quote-policy/StarChat`；移动端解析/测试/版本已由主代理提交，Task 3 核验及本记录/`docs/workflow/current-state.md` 由独立门禁代理负责，Debug/正式构建及发布证据由主代理和互不重叠代理负责。2192 源码提交 `6fc2cec93c5687cb115649c099e69728aa190aeb`；本任务候选移动源码 `dae8ec6301e4c22d09721c6f54ccc9cc90bc6f3d`。
- 最后更新时间：2026-09-29 20:58 +08:00（Task 3 全量与 Task 4 Debug 证据回读）；后续正式构建/发布记录应更新此处。
- 下一条具体操作、必要输入、阻断的验收 ID：Task 5 同源码独立构建并验证 ARM64；正式 QP-5 发布前重新读回生产 v4r2 镜像/schema/鉴权、版本占用和下载分发；真实登录账户报价及资金确认仍需授权设备反馈。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| QP-0 | 从已安装 2192 的冻结源码继承全部移动文件，无额外/缺失/链接或越界文件 | 2192 基线完成 | [基线核验](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/baseline/baseline-verification.json)：1811/1811 路径与 SHA，exit 0；[换行字节恢复记录](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/baseline/restore-result.json)：53 文件；无移动端 staged/unstaged diff | 未发布 | 已安装的 2192 Debug 身份仅作输入依据 |
| QP-1 | 报价保留 OWNER/SUPPORT 原值，缺失、错类型与未知策略拒绝 | `63eb2d02` 最小解析修复 | [Task 2 RED/GREEN](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task2-summary.md)：RED 三项预期失败、GREEN 聚焦 17/17、钱包回归 38/38；独立规格与质量/安全复核无 P0–P2 | 未发布 | 需实际报价验证 |
| QP-2 | HTTP 201 报价响应可解析，请求体与原幂等键不变 | 同上，保留响应策略原值 | MockClient 返回 201、请求体及 `idempotency-key` 原值断言，钱包回归 38/38 | 未发布 | 无 |
| QP-3 | 页面可展示 SUPPORT 报价、同键恢复报价 ID；确认前不提交出款申请 | `dae8ec63` 补强持久化恢复测试 | 同键保存 quote ID、原 key、重开只 GET 一次报价、报价 POST 一次、出款 POST 零；独立聚焦 1/1、钱包回归 38/38、analyze 0 | 未发布 | 真实账户报价待验收，不自动发起资金操作 |
| QP-4 | x86_64 Debug 从修复源码常规重建、固定证书、保留数据覆盖装入模拟器 | 已完成；`0.4.24+2193`、冻结 1811 文件、固定证书 | [Task 4 原始总结](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/android-debug/task4-summary.md)：19/19 构建步 exit 0、APK/设备 SHA 一致、`adb install -r` exit 0、firstInstallTime 未变、进程在位、有限日志无相关 FATAL/ANR | 仅模拟器安装，未公开发布 | 无测试账号；真实报价待设备验收 |
| QP-5 | 同源码 ARM64 正式包按现网门禁发布，Android 两段设置回读，iOS/API 不变 | 待构建 | 配套 v4b 同镜像经 v4r2 发布及独立验收；仍需正式发布前实时复核和源/包/分发/审计证据 | 未发布 | 发行包真实设备待验收 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源 commit | 包名/签名渠道 | 文件位置及 SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 已安装模拟器 Debug 输入 | 0.4.23+2192 | `6fc2cec93c5687cb115649c099e69728aa190aeb` | `com.liuhetong.mobile.debug` / 固定证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` | 既有 Debug `final.apk` SHA256 `34dd06bf90bdad9772914b0c0e11b76c97f824520d49eb1a2153d4679567676d`，见 2192 原任务；本任务冻结清单 SHA256 `765babd99f2e4d0959da75774a31008a4252e2bcff726b09f7a449377b396455` | 原任务 2026-09-29 已安装，本任务未重装 |
| 本任务已安装模拟器 Debug | 0.4.24+2193 | `dae8ec6301e4c22d09721c6f54ccc9cc90bc6f3d` | `com.liuhetong.mobile.debug` / 固定证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` | [最终包](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/android-debug/run-20260929-204903-2193/final.apk) 135,508,136 字节，SHA256 `167b70ab76a554c1bf7df645008926ec7ccf9d3fda690c3b9b92ba21f8cb2372`；冻结清单 SHA256 `9b04375087140c1d8b3beb31d94dc20a18e24a77ffa4121e697422bb99325dd7` | 2026-09-29 20:54:47 +08:00 模拟器保留数据覆盖安装；未公开发布 |
| 现网正式 Android | 0.4.21+2190（上轮只读观测） | `b9eca8a419614112b085439445b7fd031027a740` 及 2190 冻结输入 | `com.liuhetong.mobile` / 固定签名 | 本任务发布前重新读回，不沿用旧值 | 本任务尚未发布 |
| 正式 ARM64 待构建候选 | 0.4.24+2193，发布前再查占用 | `dae8ec6301e4c22d09721c6f54ccc9cc90bc6f3d`；`pubspec.lock` SHA256 `314504b9bf3917b30a6e12b3262eca23f774a43e4b23a88a801ae35bbea76bf3` | `com.liuhetong.mobile` / 同固定证书门禁 | 本记录时尚无正式包/SHA | 未发布 |

## 基线核验与根因

- 发行 v0.4.21+2190 和 2192 源码的 `ManualPayoutQuote.fromJson` 都只按 `OWNER_MANUAL_V1` 解析 `approval_policy`；现网业务 API 在客服出款启用时返回 `SUPPORT_MANUAL_V1`。现网 `/api/v1/wallet/manual/payout-quotes` 对登录用户开放；先前只读采样有 HTTP 201。该英文错误由客户端成功响应解析抛出，不能据此断言提现接口关闭或某位用户的申请状态。报价阶段只创建报价，不代表已冻结资金；具体用户订单须经授权查询。
- 原 2192 清单 SHA256 由 `Get-FileHash -Algorithm SHA256` 核对，源 commit 是 `6fc2cec9` 的后继文档工作树，移动端与该 commit 无差异且无未提交修改。本任务分支五个文档提交重放后，`git diff --name-only 6fc2cec9 HEAD -- apps/mobile_flutter` 为空；`pubspec.yaml` 是 `0.4.23+2192`，客户端报价解析仍仅 OWNER。
- 新工作树受全局 `core.autocrlf=true` 影响，初次 checkout 的 53 个文件磁盘字节不等于 2192 冻结源，但 Git 文件树相同。核对来源每个文件 SHA、两个工作树中 1811 个精确路径、普通文件类型、无符号链接和路径越界后，仅从 2192 工作树按字节复制这 53 个文件；未复制生成文件或改动该源工作树。`git add -u -- apps/mobile_flutter` 仅刷新索引缓存；其后 `git diff --cached --quiet`、`git diff --quiet` 均 exit 0，移动端 `git status --porcelain` 为空。最终[核验 JSON](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/baseline/baseline-verification.json)记录全部 1811 个路径和 SHA 一致、exit 0。构建工具若重新 checkout，应再次核对冻结字节，不依赖默认换行转换。
- 此阶段未运行 Flutter、后端或构建测试；此阶段仅为文档/冻结源迁移，后续测试依批准计划执行。操作系统 Windows，shell PowerShell 7，Python 进程设置 `PYTHONUTF8=1`/`PYTHONIOENCODING=utf-8`。完整命令见本任务本地基线证据目录的 `verify-baseline.py` 与 `restore-frozen-mobile-bytes.py`，输出 `baseline-verification.json`、`restore-result.json` 和对应 exit-code 文件。证据不含用户数据或凭证。

## Task 2 实现及 Task 3 源码门禁

- Task 2 使用已批准的计划和 TDD：`flutter test test/features/wallet/manual_wallet_api_test.dart test/features/wallet/manual_wallet_flow_test.dart` 在旧解析器上 exit 1，三项 SUPPORT 病例按预期抛 `Invalid manual wallet response`；最小修复仅放行两种现有策略并保留未知值拒绝。GREEN 同命令 `--no-pub` 17/17 exit 0；四个钱包文件回归 38/38 exit 0；`flutter analyze --no-pub` exit 0。版本脚本 `pwsh -NoProfile -File scripts/bump_version.ps1 -Version '0.4.24+2193'` exit 0、自带 Python 版本契约 3/3；Flutter 版本/路由 16/16。追加测试 `dae8ec63` 验证 SUPPORT 报价保存原 quote ID 和幂等键，销毁重开后 GET 一次、报价 POST 总计一次、出款 POST 为零，聚焦 1/1、四文件回归 38/38、analyze 0。原始命令/exit/日志见 [Task 2 总结](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task2-summary.md)。独立规格及质量/安全复核均通过、无 P0–P2；复核来自本任务代理结论，未另落盘审查文件。
- [2190→2192 清单与八项映射](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task3/source-delta-review.md)逐路径比较的输入 SHA 为 2190 `6b5ac7ac1c0d45eeffdd7dcec6e9453a3cd7c38244fc1c71821643fa48f341dd`、2192 `765babd99f2e4d0959da75774a31008a4252e2bcff726b09f7a449377b396455`；`compare-frozen-inputs.py` exit 0，1793→1811：18 新、93 变、0 删。范围含 2191 搜索/诊断阶段及 2192 八项反馈。原八项的 ADR-0077、实施级领域/安全审查、PG 并发、规格/质量复核和真机缺口已逐 ID 关联；本任务相对 2192 仅变更两个生产 Dart 文件、两个测试和版本清单共五个移动路径。`pubspec.lock` SHA256 `314504b9bf3917b30a6e12b3262eca23f774a43e4b23a88a801ae35bbea76bf3`，未随客户端修复变动。
- [Task 3 环境预检](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task3/preflight.json)：候选 HEAD `dae8ec63`，C: 约 88.92 GiB、D: 约 21.76 GiB 可用；Flutter 3.44.9/Dart 3.12.2（已安装 SDK 缓存版本）、Android SDK/build-tools 36.0.0、Java 17、Apktool 2.12.1、固定签名 P12/DPAPI **仅核对存在，不读取内容**。Python 3.12.10。迁移 `py -3.12 -m alembic heads` exit 0、此源码唯一 head 为 `0088_profile_grapheme_limits`；现网配套 API 的 schema 0092 属另一任务，不能把本工作树旧后端迁移当成部署来源。`py -3.12 scripts/export_openapi.py --check` exit 0。移动边界 `py -3.12 -m pytest tests/mobile -q` exit 0，238 通过/1 跳过；UI 契约 `py -3.12 scripts/verify_ui_contract.py` exit 0，32 组件/438 屏。Task 2 在最新移动源码的钱包 38/38 与 Flutter analyze exit 0 可复用，避免相同输入再跑。
- `flutter test --no-pub --reporter compact` 在本工作树的**长绝对路径**运行到 5115 通过/9 跳过/1 失败，随后 `test/widget_test.dart: renders login form` 停滞；6 分 39 秒手动中断，命令 exit 1。唯一失败是继承的 `moment_video_test.dart` 合成草稿：临时目录枚举路径 265 字符，Windows 返回 `PathNotFoundException`，随后测试队列为 null；2192 原工作树等效路径 258 字符。未修改产品或测试代码。映射本工作树至空闲 `V:` 后，同一原测试 `flutter test --no-pub --reporter expanded test/features/moments/moment_video_test.dart --plain-name 'mixed image video draft reopens and publishes with real request contract'` exit 0、1/1；再于 20:53:33–20:57:18 +08 从 `V:/apps/mobile_flutter` 执行**完整** `flutter test --no-pub --reporter compact`，exit 0、5132 通过/9 跳过/0 失败。见 [首轮长路径日志](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task3/flutter-full.log)、[短路径病例](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task3/moment-video-shortpath.log)与[最终全量日志](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task3/flutter-full-shortpath.log)。真实登录体验仍待设备。短路径全量后 `pubspec.lock` SHA 不变、移动端 Git 干净，Task 4 冻结门禁再次回读 1811 文件一致。`V:` 仅本次核验临时映射，记录提交后解除。
- `pwsh -NoProfile -File scripts/verify.ps1` 真实 exit 1：Repository policy、Deployment policy、TemplateTools 均 PASS；到 `init_matrix.ps1 -RenderOnly` 因本独立工作树没有 `.env` 而中止。没有读取/复制生产配置；同输入或相关的后段门禁按上述移动边界、OpenAPI、迁移 head、UI 契约分别补验，后端完整测试复用原 2192 不变源码的 3019 通过/78 跳过，不把本次整库脚本记为通过。[真实日志](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/task3/verify.log)。
- 原 2192 配套 v4b 候选首次激活失败后已受控回退；后续 v4r2 以**同一镜像 digest** `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd` 经独立新备份/隔离恢复和审查于约 20:00 +08 发布。原任务发布记录与独立后验确认 schema 0092、healthy/restart 0、受保护匿名 401；主任务约 20:35 +08 又只读读回该完整 digest 与 healthy/0。本任务不修改 API 或迁移，正式 APK 发布前仍须重新读取实时身份、版本占用及路由；真机钱包/视频验收不由匿名探针代替。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 2192 源码基线迁移及冻结字节核验 | 2026-09-29 19:57:16 +08:00（首个记录时钟） | 2026-09-29 20:04:01 +08:00 | 工具核验含一次换行格式恢复；更早只读检查及 rebase 起点未记录，不估算 | Task 1 | 记录区间 6 分 45 秒；最终核验 JSON UTC `12:04:01`，exit 0 | Task 2 red test |
| Task 2 RED/GREEN、版本及追加恢复测试 | 基线完成后；精确秒未记录 | 2026-09-29 20:20 前后（`task2-summary.md` 记录时刻） | 聚焦、回归、分析；不推算准确墙钟 | Task 2 | `63eb2d02`、`fba0a325`、`dae8ec63`；钱包 38/38、analyze 0 | Task 3 源码门禁 |
| Task 3 源码/环境门禁与 Flutter 路径诊断 | 2026-09-29 20:31:23 +08:00 | 2026-09-29 20:57:18 +08:00（全量结束） | 首轮长路径全量 6:39 中断，短路径病例及全量 3:45 复验；`verify.ps1` 因缺 `.env` 2 秒中止；移动边界/契约补验 | Task 3 与 Debug 构建准备并行 | 清单 +18/~93/-0；钱包 38/38、最终 Flutter 5132/9 exit 0、移动边界 238/1、契约 PASS；整库脚本真实 exit 1 | ARM64 同源码候选和正式发布前现场复核 |
| Task 4 Debug 构建及装机 | 2026-09-29 20:49:03 +08:00 | 2026-09-29 20:54:47 +08:00 | 构建 20:52:38 结束，随后设备保留数据安装与读回；Task 3 全量并行 | Task 4 / Task 3 | 19/19 步 exit 0，APK/设备 SHA 一致、固定证书与原 firstInstallTime 保留；[总结](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/android-debug/task4-summary.md) | 正式 ARM64 候选 |

已记录 Task 3 20:31:23–20:57:18 墙钟区间约 25 分 55 秒，含并行构建准备；不与其它阶段简单相加。早于首个时钟采样的操作不并入精确计时。重复工作：Windows 新 checkout 的换行转换导致首轮逐字节校验失败，已用来源 SHA 与精确路径证明后恢复；本轮一次长路径全量失败通过短盘符精确复测定因，保留原 exit 1 和最终 exit 0。

## 交接与回退

- 已确认根因/已排除假设：客户端只接受 OWNER 策略是已确认兼容缺口；服务端报价接口并非关闭。HTTP 201 的先前生产采样不能归属到具体用户。
- 待办及验收失败项：QP-0 至 QP-4 的源码、自动化和模拟器装机已完成；QP-5 的正式 ARM64 构建及受控发布待执行。配套 API v4r2 已有生产证据，仍须发布前实时复核；真实账户报价是独立体验验收。Flutter 全量最终 exit 0；整库脚本本次 exit 1 的 `.env` 环境阻断及分项补验均已保留。
- 已发布与仅候选的区别：本任务 2193 Debug 已在模拟器保留数据安装，正式 APK 仍待构建/公开发布；生产 Android 仍是上轮 2190 只读观察值，发布前重查。真实资金操作未执行。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：本阶段无生产写入、无需回退；正式发布前重新建立独立备份并在任务记录写明。
- 运行中 CI/命令/自己创建的隧道（无凭据）：本阶段无持续运行命令或隧道。
- 下次恢复先检查的事实：候选源码 `dae8ec63`、移动端冻结清单与锁 SHA、已安装 Debug 2193 SHA、ARM64 构建结果、生产 v4r2 完整 digest/schema 与 Android build 占用；`V:` 临时映射是否仍由本任务占用。
