# Android 提现报价策略兼容修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 从用户指定的 Android Debug 0.4.23+2192 冻结源码修复提现报价解析，先交付模拟器 Debug，再发布同源码的正式 ARM64 更新。

**Architecture:** 在独立工作树以 2192 源码提交 `6fc2cec93c5687cb115649c099e69728aa190aeb` 为基线；Flutter 报价模型只增加 `SUPPORT_MANUAL_V1` 这一已存在策略，其他资金与授权流程不变。冻结同一修复源码后分别生成 x86_64 Debug 和 ARM64 正式包，按固定签名重建验包；现网只更新 Android 分发。

**Tech Stack:** Flutter/Dart、PowerShell 7、Python 3.12、Apktool 2.12.1、Android build-tools 36.0.0。

---

## 文件所有权与证据基线

- 本任务工作树：`C:/Users/Administrator/.codex/worktrees/withdrawal-quote-policy/StarChat`，分支 `codex/withdrawal-quote-policy-20260929`。`chat-search-jank` 工作树与 D: 主工作区现有代码只读；D: 仅新增本任务 `docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/` 工件。
- 2192 冻结清单：`C:/Users/Administrator/.codex/worktrees/chat-search-jank/StarChat/docs/verification/artifacts/2026-09-29/android-2191-followup/android-debug/frozen-mobile-input.json`，SHA256 `765babd99f2e4d0959da75774a31008a4252e2bcff726b09f7a449377b396455`，包含该提交全部 1811 个已跟踪移动文件。已安装 Debug APK SHA256 `34dd06bf90bdad9772914b0c0e11b76c97f824520d49eb1a2153d4679567676d`，包名 `com.liuhetong.mobile.debug`、x86_64、固定证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。现网正式 Android 仍是 0.4.21+2190。
- 修改 `apps/mobile_flutter/lib/features/wallet/manual_wallet_api.dart`、`apps/mobile_flutter/test/features/wallet/manual_wallet_api_test.dart`、`apps/mobile_flutter/test/features/wallet/manual_wallet_flow_test.dart`、`apps/mobile_flutter/pubspec.yaml`、`apps/mobile_flutter/lib/core/app_config.dart`。主代理维护 `docs/workflow/tasks/2026-09-29-android-withdrawal-quote-policy.md` 与 `docs/workflow/current-state.md`。构建脚本副本、清单、日志和 APK 仅在本任务证据目录创建；发布器和静态仅在现网身份核对后有界引入，不整树复制。
- 关联[书面规格](../specs/2026-09-29-android-withdrawal-quote-policy-compatibility-design.md)、[ADR-0081](../../adr/0081-support-order-settlement-and-staff-activation.md)、[移动交付流程](../../runbooks/mobile-delivery-workflow.md)、[固定 APK 重建](../../runbooks/android-apk-rebuild.md)、[生产工作流](../../runbooks/admin-production-workflow.md)和[轻量发布门禁](../../runbooks/release-metadata.md)。此兼容修复不改变资金状态、托管合同、认证或 OpenAPI，沿用已批准 ADR。

## Task 1：建立 2192 独立源码基线

- [ ] **Step 1:** 在 PowerShell 7 设置无 BOM UTF-8 输入/输出/管道及 `PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`；确认本任务分支只有已提交规格/旧计划。`git merge-base --is-ancestor b9eca8a419614112b085439445b7fd031027a740 6fc2cec93c5687cb115649c099e69728aa190aeb` 必须 exit 0，2192 清单自身 SHA 必须等于上文完整值。
- [ ] **Step 2:** 将本任务仅文档的提交移植到 `6fc2cec9` 上；不编辑 `chat-search-jank`。移植后 `git diff --name-only 6fc2cec9 HEAD -- apps/mobile_flutter` 预期为空，目标 `pubspec.yaml` 为 `0.4.23+2192`，报价解析仍只有 OWNER。逐一对照清单核验 1811 个 `git ls-files -- apps/mobile_flutter` 路径及 SHA，拒绝清单外文件、缺文件、链接和越界；不复制旧生成文件。
- [ ] **Step 3:** 按 `docs/workflow/task-template.md` 建任务记录，写授权、根因、基线提交、验收 ID（解析、同键恢复、Debug 安装、正式发布）、文件所有权、阶段起点和下一步；`current-state.md` 顶部加入链接。保存基线核验真实 exit code、完整 SHA 和时间，不记录用户信息或凭证，提交台账。

## Task 2：测试先行修复客户端并递增版本

- [ ] **Step 1: Red:** 在 `manual_wallet_api_test.dart` 添加下列报价样本测试，SUPPORT 断言应在旧代码失败，旧 OWNER 和未知值断言仍通过：

      test('payout quote accepts the two published approval policies only', () {
        expect(ManualPayoutQuote.fromJson(quote).approvalPolicy,
            'OWNER_MANUAL_V1');
        expect(ManualPayoutQuote.fromJson({
          ...quote,
          'approval_policy': 'SUPPORT_MANUAL_V1',
        }).approvalPolicy, 'SUPPORT_MANUAL_V1');
        expect(
            () => ManualPayoutQuote.fromJson({
                  ...quote,
                  'approval_policy': 'UNKNOWN_POLICY',
                }),
            throwsFormatException);
      });

  同文件 MockClient 对 `/wallet/manual/payout-quotes` 返回 HTTP 201、其他响应保持 200；现有 `payout quote create read cancel HTTP contracts` 用 SUPPORT 响应并断言策略原值、请求体和 `idempotency-key`。在 `manual_wallet_flow_test.dart` 现有报价展示测试中用 SUPPORT、未来到期时间或固定 clock，断言金额、零费用、目标地址、到期信息、确认按钮可见，且报价阶段无 `/payouts` POST；复用既有同键恢复测试确认 quote ID 和原 key 保留。
- [ ] **Step 2:** 在 `apps/mobile_flutter` 运行 `flutter test test/features/wallet/manual_wallet_api_test.dart test/features/wallet/manual_wallet_flow_test.dart`，保存真实 exit code 与 `Invalid manual wallet response` 失败。若环境/夹具先失败，先修测试问题，不修改生产解析器。
- [ ] **Step 3: Green:** 在 `manual_wallet_api.dart` 的 `_literal` 邻近加入报价专用函数，并只将 `ManualPayoutQuote.fromJson` 中 `approval_policy` 那一次 `_literal` 替换为 `_approvalPolicy(json)`：

      String _approvalPolicy(Map<String, dynamic> json) {
        final value = _string(json, 'approval_policy');
        if (!const {'OWNER_MANUAL_V1', 'SUPPORT_MANUAL_V1'}.contains(value)) {
          _invalid();
        }
        return value;
      }

  缺字段、错类型、未知策略继续拒绝；不改其他字段、服务端策略、支付授权/MFA、幂等键或自动重试。
- [ ] **Step 4:** 运行 `flutter test test/features/wallet/manual_wallet_api_test.dart test/features/wallet/manual_wallet_flow_test.dart test/features/wallet/manual_recovery_test.dart test/features/wallet/wallet_withdraw_ui_test.dart`、仅修改 Dart 文件的 `dart format` 和 `flutter analyze`；记录 red 转 green，核对报价 ID 只在解析成功后保存、同键恢复沿用原 key、报价阶段不冻结。提交最小修复。
- [ ] **Step 5:** 实时核对模拟器 Debug build、生产 Android/iOS build 和其他任务占用；若 `0.4.24+2193` 未使用，在本任务工作树运行 `pwsh -NoProfile -File scripts/bump_version.ps1 -Version '0.4.24+2193'` 同步 `pubspec.yaml`/`app_config.dart`，否则取下一未占用值并更新本计划发布身份。运行 `pytest tests/mobile/test_app_build_contract.py`、版本相关 Flutter 测试，确认锁文件未意外变化，提交版本递增。iOS 包与设置不动。

## Task 3：最终源码门禁与独立审查

- [ ] **Step 1:** 以正式 2190 r3 清单与 Debug 2192 清单逐文件比较，记录已知的 18 新增、93 变更、0 删除并逐项关联八项任务记录。2192 的视频诊断、充值绑定门禁和头像版本依赖配套 API v4b；现网旧 API 不能提供完整端到端保证，尤其客户端门禁不能替代服务端充值写门禁。核对已批准 ADR、实施级领域/质量安全审查及真机缺口；正式发布前需读回 v4b 实际上线/验收证据。v4b 由原八项任务按其已获授权的独立发布计划完成，本任务不抢改该工作树或绕过其门禁；若尚未上线，本任务可完成 Debug 和正式候选构建，但不宣称八项完整上线。
- [ ] **Step 2:** 短预检本地环境文件是否存在（不输出内容）、Flutter/SDK/Java/Apktool/磁盘、依赖锁、迁移 head 与 OpenAPI；运行受影响钱包测试、2190→2192 变更覆盖的 Flutter 测试及 `flutter analyze`。按 `mobile-delivery-workflow.md` 输入复用规则运行适用 Flutter 全量和 `pwsh -NoProfile -File scripts/verify.ps1`，记录命令、输入 SHA、真实退出码/通过数/已知无关基线失败，未执行项不得写成通过。
- [ ] **Step 3:** 规格符合性审查先核对 2192 继承、两策略、未知拒绝、HTTP 201、同键报价恢复和确认前不提交 `/payouts`；领域与质量安全审查再核对支付验证、MFA、幂等、会话范围、财务状态机不变、2190→2192 附带改动及无敏感日志。关闭 P0–P2 后冻结源码 commit、依赖锁 SHA、版本/build 与真实登录场景待验收项。

## Task 4：x86_64 Debug 构建与模拟器覆盖安装

- [ ] **Step 1:** 以 2192 的 `freeze-mobile-input.py`、`build-android-debug.ps1`、`frozen-input-gate.ps1`、`verify_debug_payload_x64.py` 与配套语义门禁为范本，在本任务 C: 证据目录创建新副本；冻结生成器的 `ROOT`/`OUTPUT`、驱动旧 `chat-search-jank` 绝对路径、`0.4.23`/`2192`、输出目录与成功标志都精确改成本任务路径/最终版本。保留 HTTPS 三个 dart-define、性能诊断、x86_64 ABI、Apktool 2.12.1、build-tools 36.0.0、固定签名和完整验证。记录旧/新脚本 SHA，不调用旧脚本，不生成新密钥。
- [ ] **Step 2:** 本工作树运行 `flutter pub get`；准备本工作树自己的 `apps/mobile_flutter/build` 普通目录。用本任务修改后的 `freeze-mobile-input.py` 生成新清单，覆盖**全部已跟踪** mobile 文件的路径/SHA 和当前 source commit，使用新 `frozen-input-gate.ps1` 回读并确认无未提交 mobile 修改；新文件数以实际提交为准，不能硬编码 1811。确认 P12/DPAPI 文件存在、`R:` 映射准确指本工作树、模拟器旧安装为 2192 且证书一致；新驱动 `-PreflightOnly` 通过后才构建。
- [ ] **Step 3:** 从已冻结源码构建 standard x86_64 Debug 源 APK，完成常规 DEX/资源/清单重建、zipalign、固定签名；运行 Debug 载荷、apksigner、aapt、资源/DEX/清单/资产语义门禁。记录最终 `final.apk` SHA/大小、`com.liuhetong.mobile.debug`、版本/build、证书及每步 exit code；原始 Flutter APK 不作为交付品。
- [ ] **Step 4:** `adb devices -l` 确认 `emulator-5556` 在线；安装前记录旧 2192 包名/版本/firstInstallTime/证书；执行 `adb -s emulator-5556 install -r --no-streaming <本次 final.apk>`，不卸载、清数据或降级。读回新版本、firstInstallTime 未变、进程/窗口和有界 crash/ANR 日志；没有授权测试账号时真实报价交互标记待验收，绝不发起资金申请。

## Task 5：同源码正式 ARM64 固定签名构建

- [ ] **Step 1:** 从 Debug 已验证的修复 commit 创建第二个独立托管工作树作正式构建；核对 `git rev-parse HEAD`、全部 mobile 路径/SHA 与 Debug 冻结清单相同，且不带 Debug 生成目录。D: 正式产物位于 `D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2193/release/`。
- [ ] **Step 2:** 将 2190 的 `build-android-2190-arm64.ps1` 与同目录 `freeze_mobile_input.py` 一并复制到上述 release 目录；精确更新 `$version`、`$build`、Worktree、冻结工具 `VERSION`/`BUILD`、pubspec/app_config 正则与成功标志，记录旧/新 SHA。保留固定证书、ARM64 单 ABI、HTTPS 三项与性能诊断、Apktool/zipalign/签名和独立语义门禁。驱动要求 `apps/mobile_flutter/build` 为指向本次 `release/build-temp` 的 junction，并使用不同 `S:`/`T:` 虚拟盘符；确认路径均位于本任务工作树/证据目录且无进程占用后创建。
- [ ] **Step 3:** 正式工作树运行 `flutter pub get`；新冻结工具 `create`/`verify` 生成 source 与两个 generated 输入清单，记录完整 SHA。只读确认生产 Android/iOS build、正式包名与候选版本未被占用；在驱动要求的 30 分钟现场观测窗口内运行 `-PreflightOnly`。构建 ARM64 正式源包，再常规重建/对齐/固定签名；对源/最终包运行 `scripts/verify_android_release.py`、aapt、apksigner、zipalign 及 ABI/DEX/资产/清单语义比对。最终必须是 `com.liuhetong.mobile`、仅 arm64-v8a、非 debuggable、证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；保存 SHA、大小和真实退出码。

## Task 6：Android 两段生产发布与回读

- [ ] **Step 1:** 按生产工作流读取当次 Android/iOS 设置、HK 别名、CDN 对象、下载页/registry SHA、API/Worker 镜像与 schema；核对八项任务 API v4b 的实际生产镜像、schema、ready/auth 探针及独立发布审查/回退证据已完成。该前置不满足时保留本任务已验 Debug 和正式候选，停止正式发布写入。2192 基线发布器早于现网网络择优功能：先核对服务器实际静态和 2190 证据，再有界引入现行 `scripts/release_metadata.py`、`scripts/release_settings.py`、下载页/网络选择 JS 及 `tests/mobile/test_network_release_metadata.py`、`tests/mobile/test_release_settings.py`。D: 主目录这些文件部分未提交且部分已相对现网漂移，不能整批覆盖；运行三个发布器专项 `pytest`，生成与在线非 Android 区段一致的静态增量，源码静态随任务提交。来源无法对齐时停止发布写入。
- [ ] **Step 2:** 将 2190 的 `publish_binary.py`、`publish_cdn.py`、`update_cdn_behavior.py` 有界复制为本任务脚本，逐项更新硬编码版本、路径、大小和 SHA，并审查上传/原子切换/回退。先保存实时 CDN 分发配置、ETag 与对象策略；旧脚本只支持 2188/2190 两条精确行为/对象，本次必须以 ETag CAS 增补 2193 第三条，保留旧 2188 与 2190 路径及授权，不能用两对象旧策略覆盖现网。正式包与构建 SHA 一致；香港/新加坡新精确对象上传后 SHA/长度一致，三个版本路径分别核对 HEAD、206 Range、CORS 与缓存。香港 `latest-arm64.apk` 别名原子切换并记录前后目标与独立恢复步骤。
- [ ] **Step 3:** 从最终 APK 真实 version/build/大小/SHA 构造 `release-standard.json`（Android 直链）和 `release-network.json`（同版本/build/香港不可变 URL，含 `network_selection=true`、精确 CDN URL、三个在线静态资源 SHA）。`signing_confirmed_by` 写本次 apksigner 固定证书的实际核验责任/方式。先标准记录 `prepare/check/publish` 更新 Android 版本/build/直链三字段，保存第一段独立 0700 备份/审计/回读；之后才以网络记录相同命令把 Android 更新入口恢复网络择优 URL，仅改 APK URL，保存第二段独立备份/审计/回读。数据库结果未知先查审计和现值，不盲重试。
- [ ] **Step 4:** 服务器与工作站分别核对严格 TLS ready 200、提现匿名 401、两路 APK HEAD/长度及 CDN 206/CORS、官网/registry/版本设置、两段审计和旧包回退链接；确认 iOS 包/设置及 API 镜像不变。关闭临时 SOCKS，更新台账/报告，分别标注“代码通过、Debug 已安装、正式包已发布、真实账户报价待验收”。失败按阶段从本次静态/设置/别名备份恢复精确前态，不删除报价、申请、审计或账本。
