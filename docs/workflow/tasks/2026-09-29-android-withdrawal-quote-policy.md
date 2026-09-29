# Android 提现报价策略兼容修复任务记录

## 恢复入口

- 目标、用户授权来源及边界：修复发行 Android v0.4.21+2190 点击提现后出现 `Invalid manual wallet response`；用户批准客户端兼容方案、书面规格，并要求以 Android Debug v0.4.23+2192 为源码基础，先交付模拟器 Debug，再发布正式 ARM64 更新。用户已批准[修订计划](../../superpowers/plans/2026-09-29-android-withdrawal-quote-policy-compatibility.md)实施及发布。只接受服务端现有的 `OWNER_MANUAL_V1`、`SUPPORT_MANUAL_V1` 报价策略；资金权限、幂等、服务端与 iOS 行为不在改动范围。正式发布须等待另一任务的 API v4b 安全发布并通过现网门禁。
- 关联计划/ADR：[书面规格](../../superpowers/specs/2026-09-29-android-withdrawal-quote-policy-compatibility-design.md)、[修订计划](../../superpowers/plans/2026-09-29-android-withdrawal-quote-policy-compatibility.md)、[ADR-0081](../../adr/0081-support-order-settlement-and-staff-activation.md)。
- 当前状态：2192 基线完成；解析修复测试先行待开始。未构建或安装本任务 Debug，未发布正式更新。
- 负责人、工作树、文件所有权、源码 commit：本任务 `codex/withdrawal-quote-policy-20260929`，`C:/Users/Administrator/.codex/worktrees/withdrawal-quote-policy/StarChat`；移动端解析/测试/版本、构建与本任务发布证据由主代理继续实施；本记录与 `docs/workflow/current-state.md` 为基线记录。本任务规格和计划五个文档提交已重放到 2192 源码提交 `6fc2cec93c5687cb115649c099e69728aa190aeb` 上；当前基线文档 HEAD `6731075d5db7982330a7b9f974030114182e292c`。
- 最后更新时间：2026-09-29 20:04 +08:00（基线逐文件核验）；后续实施记录应更新此处。
- 下一条具体操作、必要输入、阻断的验收 ID：按计划 Task 2 先写 SUPPORT 报价解析、HTTP 201、页面报价/同键恢复的失败测试，再做最小解析修复。正式发布的 QP-5 须先读回 API v4b 独立上线与审查证据；真实登录账户报价需授权设备反馈。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| QP-0 | 从已安装 2192 的冻结源码继承全部移动文件，无额外/缺失/链接或越界文件 | 2192 基线完成 | [基线核验](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/baseline/baseline-verification.json)：1811/1811 路径与 SHA，exit 0；[换行字节恢复记录](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/baseline/restore-result.json)：53 文件；无移动端 staged/unstaged diff | 未发布 | 已安装的 2192 Debug 身份仅作输入依据 |
| QP-1 | 报价保留 OWNER/SUPPORT 原值，缺失、错类型与未知策略拒绝 | 待实现 | 测试先行，待记录 red/green | 未发布 | 需实际报价验证 |
| QP-2 | HTTP 201 报价响应可解析，请求体与原幂等键不变 | 待实现 | API 客户端 MockClient 回归待运行 | 未发布 | 无 |
| QP-3 | 页面可展示 SUPPORT 报价、同键恢复报价 ID；确认前不提交出款申请 | 待实现 | 页面/恢复测试待运行 | 未发布 | 真实账户报价待验收，不自动发起资金操作 |
| QP-4 | x86_64 Debug 从修复源码常规重建、固定证书、保留数据覆盖装入模拟器 | 待构建 | 签名/载荷/ADB 回读待执行 | 未发布 | 模拟器非真机 |
| QP-5 | 同源码 ARM64 正式包按现网门禁发布，Android 两段设置回读，iOS/API 不变 | 待构建 | 需 API v4b 发布验收、源/包/分发/审计证据 | 未发布 | 发行包真实设备待验收 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源 commit | 包名/签名渠道 | 文件位置及 SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| 已安装模拟器 Debug 输入 | 0.4.23+2192 | `6fc2cec93c5687cb115649c099e69728aa190aeb` | `com.liuhetong.mobile.debug` / 固定证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` | 既有 Debug `final.apk` SHA256 `34dd06bf90bdad9772914b0c0e11b76c97f824520d49eb1a2153d4679567676d`，见 2192 原任务；本任务冻结清单 SHA256 `765babd99f2e4d0959da75774a31008a4252e2bcff726b09f7a449377b396455` | 原任务 2026-09-29 已安装，本任务未重装 |
| 现网正式 Android | 0.4.21+2190（上轮只读观测） | `b9eca8a419614112b085439445b7fd031027a740` 及 2190 冻结输入 | `com.liuhetong.mobile` / 固定签名 | 本任务发布前重新读回，不沿用旧值 | 本任务尚未发布 |
| 本任务候选 | 待核对版本占用，计划 0.4.24+2193 | 尚未冻结修复 commit | Debug 与正式包分开构建 | 尚无包/SHA | 未发布 |

## 基线核验与根因

- 发行 v0.4.21+2190 和 2192 源码的 `ManualPayoutQuote.fromJson` 都只按 `OWNER_MANUAL_V1` 解析 `approval_policy`；现网业务 API 在客服出款启用时返回 `SUPPORT_MANUAL_V1`。现网 `/api/v1/wallet/manual/payout-quotes` 对登录用户开放；先前只读采样有 HTTP 201。该英文错误由客户端成功响应解析抛出，不能据此断言提现接口关闭或某位用户的申请状态。报价阶段只创建报价，不代表已冻结资金；具体用户订单须经授权查询。
- 原 2192 清单 SHA256 由 `Get-FileHash -Algorithm SHA256` 核对，源 commit 是 `6fc2cec9` 的后继文档工作树，移动端与该 commit 无差异且无未提交修改。本任务分支五个文档提交重放后，`git diff --name-only 6fc2cec9 HEAD -- apps/mobile_flutter` 为空；`pubspec.yaml` 是 `0.4.23+2192`，客户端报价解析仍仅 OWNER。
- 新工作树受全局 `core.autocrlf=true` 影响，初次 checkout 的 53 个文件磁盘字节不等于 2192 冻结源，但 Git 文件树相同。核对来源每个文件 SHA、两个工作树中 1811 个精确路径、普通文件类型、无符号链接和路径越界后，仅从 2192 工作树按字节复制这 53 个文件；未复制生成文件或改动该源工作树。`git add -u -- apps/mobile_flutter` 仅刷新索引缓存；其后 `git diff --cached --quiet`、`git diff --quiet` 均 exit 0，移动端 `git status --porcelain` 为空。最终[核验 JSON](../../verification/artifacts/2026-09-29/withdrawal-quote-2193/baseline/baseline-verification.json)记录全部 1811 个路径和 SHA 一致、exit 0。构建工具若重新 checkout，应再次核对冻结字节，不依赖默认换行转换。
- 此阶段未运行 Flutter、后端或构建测试；此阶段仅为文档/冻结源迁移，后续测试依批准计划执行。操作系统 Windows，shell PowerShell 7，Python 进程设置 `PYTHONUTF8=1`/`PYTHONIOENCODING=utf-8`。完整命令见本任务本地基线证据目录的 `verify-baseline.py` 与 `restore-frozen-mobile-bytes.py`，输出 `baseline-verification.json`、`restore-result.json` 和对应 exit-code 文件。证据不含用户数据或凭证。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 2192 源码基线迁移及冻结字节核验 | 2026-09-29 19:57:16 +08:00（首个记录时钟） | 2026-09-29 20:04:01 +08:00 | 工具核验含一次换行格式恢复；更早只读检查及 rebase 起点未记录，不估算 | Task 1 | 记录区间 6 分 45 秒；最终核验 JSON UTC `12:04:01`，exit 0 | Task 2 red test |
| 解析修复、Debug、正式构建和发布 | 尚未开始 | — | — | Task 2–6 | 未执行 | 按计划逐项填报 |

已记录总墙钟区间为 19:57:16–20:04:01 +08:00；早于首个时钟采样的操作不并入精确计时。重复工作：Windows 新 checkout 的换行转换导致首轮逐字节校验失败，已用来源 SHA 与精确路径证明后恢复，后续冻结门禁需使用字节清单。

## 交接与回退

- 已确认根因/已排除假设：客户端只接受 OWNER 策略是已确认兼容缺口；服务端报价接口并非关闭。HTTP 201 的先前生产采样不能归属到具体用户。
- 待办及验收失败项：QP-1 至 QP-5 全待执行；QP-0 已完成。现网 API v4b 前置与真实账户报价是正式发布、真实体验的独立门禁。
- 已发布与仅候选的区别：本任务尚无新 Debug、正式 APK 或生产改动。2192 是另一任务已安装的 Debug 输入，不是本修复交付。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：本阶段无生产写入、无需回退；正式发布前重新建立独立备份并在任务记录写明。
- 运行中 CI/命令/自己创建的隧道（无凭据）：本阶段无持续运行命令或隧道。
- 下次恢复先检查的事实：本工作树 HEAD、移动端 1811 文件冻结 SHA 与 Git 状态、报价解析是否仍 OWNER-only、其他任务 v4b 的实际生产状态和 Android build 占用。
