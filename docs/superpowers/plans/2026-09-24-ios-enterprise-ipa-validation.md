# iOS 企业回签 IPA 校验实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在分发前拒绝 App ID 错配、开发签名或缺失必要权益的最终企业回签 IPA，允许不同企业 Team，但只在确认与真机已安装版本兼容时进行保留数据覆盖升级。

**Architecture:** 现有 `Runner.entitlements`、iOS CI 候选包门禁和前台 Matrix 通话/通知路径均已具备所需配置；错误发生在外部企业回签后。新增本地 IPA 检查器读取同一字节快照的 `Info.plist`、CMS 描述文件、Runner Mach-O 已签权益，输出带 SHA256 的证据；Team 为调用方指定，不硬编码原企业签名。`release_metadata.py publish` 将新包证据与**真机已安装旧包**的 App ID/Keychain 基线及保留数据覆盖记录比较，并对服务器本地不可变 IPA 重新解析与核对 SHA。发布阶段仍只对公网做 HEAD 与小元数据检查，不回拉完整 IPA。无需改变 Flutter/Swift 业务逻辑，也不能用本改动修复已错误签名的 IPA。

**Tech Stack:** Python 3.11+ 标准库、系统 `openssl`/macOS `security cms`、pytest、现有 `release_metadata.py`。

---

## 边界与所有权

- `/root` 独占 `scripts/verify_ios_enterprise_ipa.py`、`scripts/release_metadata.py`、对应 `tests/mobile/` 文件、本计划、任务与验证文档；其他代理仅做只读审计。
- 企业证书、私钥和描述文件不进入仓库；校验脚本不输出令牌或私钥。签名密码与重新签名仍由原签名方完成。
- 用户允许临时使用其他企业签名，但**必须覆盖升级并保留旧应用数据**。新包可以使用任意合法 Team；若旧包 Team/App ID 与新包不同或旧 Keychain 默认组无法保留，普通企业重签不可宣称兼容，须停在旧包/设备身份调查或 Apple 特殊迁移能力证据，不通过客户端代码绕过。
- 缺少 APNs 时默认失败；如用户明确接受仅前台能力，可显式记录无 APNs 例外，但不得宣称后台来电/消息提醒通过。App ID 错配无例外。
- 现网另有并发发布流程；用户确认其暂停前只改本地源码和文档，不写生产。

### Task 1: 最终 IPA 身份检查器

**Files:** Create `scripts/verify_ios_enterprise_ipa.py`; create `tests/mobile/test_verify_ios_enterprise_ipa.py`.

- [x] **Step 1: Write failing tests.** 用内存 ZIP、最小 arm64 Mach-O CodeSignature SuperBlob 和注入的已解码 profile，覆盖任意一致的企业 Team/Bundle/version/build、profile 与已签权益 App ID 错配、Keychain group 不匹配、无 APNs、开发 `get-task-allow`、截断签名。
- [x] **Step 2: Verify RED.** Run `python -m pytest tests/mobile/test_verify_ios_enterprise_ipa.py -q`; tests failed because validator module/API was absent. Further same-byte snapshot/signed Team regressions also failed before fixes.
- [x] **Step 3: Implement minimal parser and CLI.** Parse IPA ZIP and plist, decode CMS profile through system `openssl cms -verify -noverify`, parse Runner Mach-O LC_CODE_SIGNATURE XML entitlement slot, compare both App IDs to supplied `TeamID.BundleID`, compare/record signed and profile Keychain groups, require enterprise distribution and production APNs by default, compute SHA256, emit machine-readable evidence. Unsupported Mach-O/DER-only cases fail closed with a named error.
- [x] **Step 4: Verify GREEN and malformed inputs.** Focused pytest passed; CLI rejects returned IPA's `ZXB3TS7QD4.cn.edu.buaa.bhpan.fileProvider` with exit code 1 and no passing evidence.

### Task 2: 发布记录绑定校验结果

**Files:** Modify `scripts/release_metadata.py`; modify `tests/mobile/test_release_metadata.py`.

- [x] **Step 1: Write failing tests.** iOS `publish` rejects missing/failed evidence, wrong Team.Bundle relationship, lack of matching installed-old-app upgrade baseline and device data-preservation record, lost default/previous Keychain groups, forged inspection evidence, and server local IPA SHA mismatch before static/DB writes; same-size IPA replacement during page verification is caught before settings apply. Android remains unaffected. Include explicit no-APNs exception behavior.
- [x] **Step 2: Verify RED.** Run focused pytest; separate batches failed for intended missing guard, Keychain/race, old baseline, and forged evidence/device record.
- [x] **Step 3: Implement minimal binding.** Validate evidence fields against release record and old installed IPA baseline; at `publish` reinspect and compare the uploaded IPA to verified evidence, plus SHA256 under publisher lock before touching static files, then recheck before DB apply. Keep existing public HEAD and metadata gates.
- [x] **Step 4: Verify GREEN.** Both focused test files pass, 71 cases; legacy Android path and existing iOS metadata checks pass with updated fixtures.

### Task 3: 操作手册与验证

**Files:** Modify `docs/runbooks/release-metadata.md` and `docs/runbooks/mobile-delivery-workflow.md`; create `docs/workflow/tasks/2026-09-24-ios-enterprise-ipa-validation.md` and `docs/verification/2026-09-24-ios-enterprise-ipa-validation.md`; update `docs/workflow/current-state.md`.

- [x] **Step 1: Record command, evidence schema and explicit APNs exception.** Document final signed local IPA validation, device record and server local reinspection, preserving no-public-redownload rule.
- [x] **Step 2: Run focused and required gates.** Python/pytest and `scripts/verify.ps1` environment preflight passed. Final affected tests: 76 focused, mobile 170 passed/1 skipped, UI contract and policies passed; two full script attempts were intentionally stopped during unchanged backend tests under the documented impact/evidence-reuse rule. Record exact commands, exit codes, SHA and limitations in the verification note.
- [x] **Step 3: Review.** Specification-compliance review preceded quality/security review; reported P1 flaws were fixed and independently re-reviewed. Current bad IPA fails, no production write occurred, and no actual iPhone installation is claimed.

This plan is authorized by the user's request to modify source for the observed iOS distribution failure. If the user selects foreground-only work instead, revise the scope before implementing unrelated call logic.
