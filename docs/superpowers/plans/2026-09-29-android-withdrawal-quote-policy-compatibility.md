# Android 提现报价策略兼容修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 修复 Android 0.4.21+2190 对成功客服提现报价的误判，并交付保留原账号数据的下一版 ARM64 正式更新。

**Architecture:** 从正式 2190 的 r3 冻结清单重建独立移动端源码基线；Flutter 报价模型只增加 SUPPORT_MANUAL_V1 这一已定义策略，保留所有其他解析、支付授权及幂等路径。Android 增量版本按固定签名重建，在生产实时身份核对后只更新 Android 分发与设置。

**Tech Stack:** Flutter/Dart、FastAPI 既有只读契约、PowerShell 7、Python 3.12、Apktool 2.12.1、Android build-tools 36.0.0。

---

## 文件所有权和入口

- 工作树：C:/Users/Administrator/.codex/worktrees/withdrawal-quote-policy/StarChat，分支 codex/withdrawal-quote-policy-20260929；不得编辑 D:/pythonProject/outsource/StarChat 的大量既有未提交文件。
- 冻结来源：C:/Users/Administrator/.codex/worktrees/diagnostic-fidelity/StarChat，只读；其 1793 个 mobile 源文件及两个当时生成输入已经通过 r3 清单校验。
- 正式 r3 清单：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json，SHA-256 `6b5ac7ac1c0d45eeffdd7dcec6e9453a3cd7c38244fc1c71821643fa48f341dd`。
- 本任务独有 copier、测试日志、冻结清单与 APK 位于 `D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-29/withdrawal-quote-2191/`；代码仍只在 C: 的本任务工作树改动。2190 构建驱动要求源码盘符与产物盘符不同，故产物放 D: 且不复用旧目录。D: 主目录仅新增本任务验证工件，不改其既有未提交代码。
- 修改 apps/mobile_flutter/lib/features/wallet/manual_wallet_api.dart、apps/mobile_flutter/test/features/wallet/manual_wallet_api_test.dart、apps/mobile_flutter/test/features/wallet/manual_wallet_flow_test.dart；版本确定后修改 apps/mobile_flutter/pubspec.yaml 和 lib/core/app_config.dart，并按下文有界同步 `scripts/bump_version.ps1` 与 `tests/mobile/test_app_build_contract.py`。任务文档归本任务主代理，代理不得并发编辑同一文件。
- 关联[书面规格](../specs/2026-09-29-android-withdrawal-quote-policy-compatibility-design.md)、[ADR-0081](../../adr/0081-support-order-settlement-and-staff-activation.md)、[移动交付流程](../../runbooks/mobile-delivery-workflow.md)、[固定 APK 重建](../../runbooks/android-apk-rebuild.md)和[轻量发布门禁](../../runbooks/release-metadata.md)。本修复不改资金状态机、托管合同或 OpenAPI，不新增受保护 ADR。

## Task 1：恢复并冻结正式 2190 源码基线

- [ ] **Step 1:** 在 PowerShell 7 设置无 BOM UTF-8 输入/输出/管道及 PYTHONUTF8=1、PYTHONIOENCODING=utf-8；记录工作树 HEAD 和 apps/mobile_flutter 的 Git 状态。确认目标仅有已提交规格/计划、mobile 子树无本任务改动。目标 HEAD 的祖先必须为 b9eca8a419614112b085439445b7fd031027a740。
- [ ] **Step 1a:** 按 docs/workflow/task-template.md 建立 `docs/workflow/tasks/2026-09-29-android-withdrawal-quote-policy.md`，填写本任务的授权、根因、工作树、验收 ID、阶段起点与下一条可执行操作；每次门禁与发布阶段更新真实时间、输入 SHA 和退出码。把任务记录链接加入 current-state.md 最新位置，历史状态只作背景。
- [ ] **Step 2:** 对只读来源运行正式冻结工具：

      py -3.12 D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/freeze_mobile_input.py verify --repo C:/Users/Administrator/.codex/worktrees/diagnostic-fidelity/StarChat --manifest D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json --expected-sha256 6b5ac7ac1c0d45eeffdd7dcec6e9453a3cd7c38244fc1c71821643fa48f341dd

  预期 exit 0、build=2190、version=0.4.21、file_count=1793。先以 Get-FileHash 对清单本身复核完整 SHA。
- [ ] **Step 3:** 在本任务验证目录创建并运行 copy_frozen_2190.py。脚本只以 r3 清单 files[] 为允许集合：逐项拒绝绝对路径、反斜线、点段、符号链接和越出 apps/mobile_flutter 的解析路径；先核对来源每项 SHA，再以 `git ls-files -co --exclude-standard -- apps/mobile_flutter` 检查目标没有清单外文件；仅把哈希不同的普通文件复制到目标对应路径；最后对目标 1793 个文件逐项回读 SHA、核对该命令所列路径集合完全相等。任何差异退出非零且不得继续。该脚本不复制清单中两个 generated_inputs，也不删除或移动目录。
- [ ] **Step 4:** 记录与旧 HEAD 的实际恢复差异（预估 378 项，含 136 个新增，以实测为准）；运行 flutter pub get 正常再生目标 .dart_tool/package_config.json 和 .flutter-plugins-dependencies，确认依赖锁 pubspec.lock 未意外变化且生成路径指向新工作树。若工具生成源文件变化，先解释并重新核对 1793 源文件 SHA。以单独提交保存恢复的正式 2190 mobile 源码；提交中不含密钥、.env 或生成缓存。

## Task 2：测试先行修复报价解析

- [ ] **Step 1: Red:** 在 manual_wallet_api_test.dart 添加以下紧邻现有 quote 夹具的独立用例，先让 SUPPORT 成功断言失败，OWNER 与未知值断言继续通过：

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

  在同文件的 `setUp` MockClient 中，仅对 `/wallet/manual/payout-quotes` 返回 201，其他响应保持 200；现有 `payout quote create read cancel HTTP contracts` 测试把 `response = quote` 改为 `response = {...quote, 'approval_policy': 'SUPPORT_MANUAL_V1'}`，并断言 `approvalPolicy` 原样返回，保留其 `contract(...)` 对 Idempotency-Key 与请求体的断言。在 manual_wallet_flow_test.dart 的 `quote displays locked destination...` 中把成功响应夹具加入 `'approval_policy': 'SUPPORT_MANUAL_V1'`，收集请求并断言只出现一次 `/payout-quotes`、尚无 `/payouts`，报价页仍显示原金额、零费用、地址和确认按钮；用未来的 fixture expires_at 或注入测试 clock，避免旧日期让确认按钮过期。报价恢复测试沿用现有 `ManualOperationStore` 的 key/id 断言，不创建第二笔。
- [ ] **Step 2:** 在 apps/mobile_flutter 运行 `flutter test test/features/wallet/manual_wallet_api_test.dart test/features/wallet/manual_wallet_flow_test.dart`；记录真实 exit code 与 SUPPORT 用例的 `Invalid manual wallet response` 失败。若失败源是环境/夹具，先修测试环境，不改生产代码。旧 OWNER 样本应保持通过。
- [ ] **Step 3: Green:** 在 manual_wallet_api.dart 增加仅用于报价策略的校验函数：

      String _approvalPolicy(Map<String, dynamic> json) {
        final value = _string(json, 'approval_policy');
        if (!const {'OWNER_MANUAL_V1', 'SUPPORT_MANUAL_V1'}.contains(value)) {
          _invalid();
        }
        return value;
      }

  在 ManualPayoutQuote.fromJson 中只把原 _literal(json, 'approval_policy', 'OWNER_MANUAL_V1') 换成 _approvalPolicy(json)。不得更改服务端策略、其他字段校验、报价请求体、支付密码/TOTP、会话范围或自动重试行为。
- [ ] **Step 4:** 在 apps/mobile_flutter 重跑 `flutter test test/features/wallet/manual_wallet_api_test.dart test/features/wallet/manual_wallet_flow_test.dart test/features/wallet/manual_recovery_test.dart test/features/wallet/wallet_withdraw_ui_test.dart`；检查既有同键报价恢复依旧使用原 key 且解析成功后才保存 quote id。对这三个已修改 Dart 文件运行 `dart format`，再执行 `flutter analyze`；对实际修改文件做差异与敏感值检查，提交最小修复。

## Task 3：最终候选门禁与独立审查

- [ ] **Step 1:** 以 2190 `tooling-sync.json` 为准，从 D: 主目录有界同步 `scripts/bump_version.ps1`（SHA `5b877e0871739caa34bd2199f443efe42762f1ce2d722b56c35d8643c32bb709`）和 `tests/mobile/test_app_build_contract.py`（SHA `d31f9391360cff9052652cf6458659a90675e686424ae2007f51baa9dbed13c0`）到独立工作树，确认二者含 `compiledBuildNumber`，运行 `pytest tests/mobile/test_app_build_contract.py`。然后只读核对生产 Android/iOS 版本设置、现行 APK 渠道与并行任务版本占用；只有 0.4.22+2191 仍未使用时，把 pubspec.yaml、app_config.dart 的版本/build 同步从 0.4.21+2190 递增。否则选实际下一未占用值并先更新本计划的发布身份记录。iOS 构建/设置不动。
- [ ] **Step 2:** 在冻结候选源码和依赖锁上运行受影响 Flutter 钱包专项、共享逻辑相关门禁、flutter analyze；按 mobile-delivery-workflow 的输入复用规则运行适用完整测试。先预检本地环境文件是否存在（不输出内容）、SDK/Java/磁盘/唯一迁移 head/OpenAPI，再运行一次 pwsh -NoProfile -File scripts/verify.ps1；所有命令记录真实 exit code、输入 SHA、时长、旧基线失败及日志，不用环境阻断伪称通过。
- [ ] **Step 3:** 先由独立审查者按本规格逐条检查两策略解析、成功报价/同键恢复、未知策略拒绝、仅报价不冻结；再由领域与质量安全审查检查支付验证、MFA、幂等键、会话范围、财务状态机及无敏感日志。关闭 P0–P2 后冻结候选，记录审查身份和最终源码 SHA。

## Task 4：ARM64 固定身份 APK 构建

- [ ] **Step 1:** 将已验证的 `build-android-2190-arm64.ps1` 与其同目录 `freeze_mobile_input.py` **一并**复制到 D: 本任务验证目录，保留原件 SHA；对新副本做精确版本替换：`VERSION="0.4.21"`、`BUILD=2190`、两个冻结工具正则及报错，驱动的 `$version`、`$build`、Worktree 默认路径、pubspec/app_config 正则与成功标志均改为最终候选版本/build/本工作树。检查旧值不再残留于版本断言，记录两份新脚本 SHA。驱动通过 `$PSScriptRoot` 加载新冻结工具；保留原 Apktool 2.12.1、build-tools 36.0.0、`S:`/`T:` 不同虚拟盘符、签名身份和全部源/最终包门禁。先确认 P12 与 DPAPI 文件存在；禁止创建新密钥、打印密码或复用 2190 输出。
- [ ] **Step 2:** 在 apps/mobile_flutter 正常运行 `flutter pub get`，用新冻结工具 `create --repo <本工作树> --manifest <本任务目录/frozen-mobile-input-2191.json>` 生成本版 source/generated 输入清单，记录完整 SHA 并立即用 `verify` 回读。为构建创建本任务目录 `build-temp`；若 apps/mobile_flutter/build 尚不存在，创建指向该目录的 junction；若已存在，先辨认其目标，只有属于本工作树且可安全转移的生成目录才处理，绝不移走别人的输出。运行构建驱动 `-PreflightOnly`，传入刚读出的生产 Android/iOS build 与观测时间，核对包名 com.liuhetong.mobile、固定证书指纹 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff、HTTPS Business API/Matrix/Getui/性能诊断参数和 arm64 工具；预检不通过不启动构建。
- [ ] **Step 3:** 构建 standard release ARM64 源 APK，常规 DEX/资源/清单重建、zipalign、固定签名；运行 apksigner、zipalign、aapt、ABI/DEX/资产/清单语义与 scripts/verify_android_release.py 源包和最终包检查。保存最终 APK 的 SHA、大小、包名、versionCode/versionName、证书、工具版本和逐门禁 exit code。真机可用时先核对在线设备和已安装版本，再保留数据覆盖安装并实际走客服报价；没有授权测试账号时把真实提现交互列为待验收。

## Task 5：恢复当前发布器并受控发布 Android

- [ ] **Step 1:** 新工作树 Git 基线的发布器/网页早于现网网络择优功能；先按 `docs/runbooks/admin-production-workflow.md` 只读取得现网静态文件、发布器及 Android 设置的路径/SHA，并与 2190 `verify_android_publication.py`、`release-network.json` 的静态/脚本身份比对。再从 D: 主目录有界引入 `scripts/release_metadata.py`、`scripts/release_settings.py`、`frontend/download.html`、`frontend/src/admin-home.js`、`frontend/src/download-redirect.js`、`frontend/src/download-network.js`、`frontend/src/download-network-selector.js` 及 `tests/mobile/test_network_release_metadata.py`、`tests/mobile/test_release_settings.py` 到本任务工作树；逐个记录来源/目标 SHA、Git 状态，拒绝整树复制。`download.html` 与 `download-redirect.js` 在主目录已相对 2190 发生漂移，必须以当次线上内容和相关任务所有权逐项审查；不能直接拿其现值覆盖现网。运行 `pytest tests/mobile/test_release_metadata.py tests/mobile/test_network_release_metadata.py tests/mobile/test_release_settings.py`，确认网络择优保护、iOS 隔离与标准发布器通过。若页面来源和在线版本的可保留区段仍不一致，暂停发布阶段，先形成可审查的静态增量和对应回归。
- [ ] **Step 2:** 重新读取实时生产 Android/iOS 设置、下载页、HK 直连/CDN 现行包身份、API/Worker 镜像与 schema；保留旧版 2190 不可变包与静态/设置回退路径。将旧 `publish_binary.py` 与 `publish_cdn.py` 有界复制为本任务专用脚本，逐项替换硬编码 2190 版本、路径、字节数和 SHA，审查备份、幂等与错误退出。核对新 APK 与 build 记录 SHA 精确相同，香港和新加坡精确对象上传后 SHA/长度相同；新 CDN 精确路径按旧路径复制必要 CORS/Range/缓存行为并检查 206 与跨域，旧包不覆盖。香港 `latest-arm64.apk` 别名原子切换到新不可变包，记录切换前后目标与恢复动作；它与数据库更新分开验收。
- [ ] **Step 3:** 从本次 final APK 的真实 version/build/字节/SHA 构造两个明确 JSON：`release-standard.json` 为普通 Android 直链记录；`release-network.json` 同版本/build、同不可变 `artifact_url`，另含 `network_selection=true`、精确 CDN URL 与三个当前静态资源 SHA。`signing_confirmed_by` 填本次实际本地 apksigner 固定证书核验责任与方式，不复制旧包描述。先用标准 JSON `prepare/check/publish` 把 Android 三字段更新为新版本，并保存**独立**备份/审计/回读；标准记录成功后才以网络 JSON `prepare/check/publish` 把更新入口恢复为网络择优页，仅变更 Android APK URL，并保存第二份独立备份/审计/回读。源码中的下载页与 registry 等生成静态也提交，避免后续站点发布复活旧版。所有远端命令走既有 jumper/脚本，保持主机密钥与 HTTPS 校验；未知写入先查审计/现值，不盲重试。绝不发起真实资金提现作为发布冒烟。
- [ ] **Step 4:** 服务器与工作站分别核对严格 TLS JSON ready、提现匿名 401、两路 APK HEAD/长度、206/CORS、页面与 registry 身份、Android 版本设置/两段审计及旧包回退链接；确认 iOS 设置与包不变，关闭临时 SOCKS 隧道。更新任务台账按“代码通过/包通过/已发布/真实会话待验收”分别记录，保留两段完整 rollback 位置；失败按冻结前态与发布阶段恢复精确 Android 静态/设置，不删除服务端报价或财务审计。
