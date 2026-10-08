# iOS History Repair IPA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a newly built iOS device IPA containing the verified history/weak-network/voice repair, ready for user enterprise re-signing.

**Architecture:** Reuse clean attached worktree/source3c37b529 via codex/ios-history-ipa-2205. Build unsigned full-device release on the established GitHub macOS/Xcode stack. Validate native storage on a separate synthetic simulator host and preserve every production plugin in the IPA.

**Tech Stack:** Flutter3.44.9/Dart3.12.2, macos-15/Xcode26.3, CocoaPods, Python3.12/pytest8.4.2, PowerShell7/GCM REST access.

**Spec:** [Authorized packaging scope](../specs/2026-10-08-ios-history-ipa.md).

## Global Constraints

- 0.4.36+2205, Bundle ID com.liuhetong.liuhetongMobile, iOS16.0 target; financial/E2EE/account policy unchanged.
- No enterprise keys/profile, Apple upload, main merge, production setting/static link/popup writes.
- Full plugins for device; scanner exclusion only for synthetic simulator harness and labeled.
- Preserve existing dependency versions and official URLs via enforce-lockfile; generated CocoaPods lock is evidence.
- Serialized U Flutter/Dart; temporary evidence only docs/verification/artifacts/2026-10-08/ios-ipa-history-fix.

## Review Focus

- Simulator architecture falsely packaged as a device IPA.
- Wrong source/version, stale assets or pub drift during dependency restore.
- Native iOS library loader/blobs versus successful Windows host tests.
- Unsigned source entitlements versus actual enterprise-signed Team/Keychain/APNs rights.
- Failed native gate/job retried or artifact downloaded without binding exact run/head/attempt SHA.

## Task 1: Source/version freeze (root)

Files: apps/mobile_flutter/pubspec.yaml, lib/core/app_config.dart; task/spec/plan/index and artifact metadata.

- [x] Confirm live repository/CI/version occupancy; use new bounded codex branch from6ae; preserve primary WIP.
- [x] Run scripts/bump_version.ps1 0.4.36+2205 and focused version/runtime/update identity tests; unchanged core SHA proof.
- [x] Freeze source/lock/native configuration hashes and document reused5632 full/analysis evidence and native gaps.

## Task 2: Unsigned packaging pipeline (one implementer)

Pipeline owns: .github/workflows/ios-enterprise-package.yml; scripts/prepare_ios_unsigned_ipa.py; tests/mobile/test_ios_unsigned_package.py. Native preflight owns new apps/mobile_flutter/integration_test/ios_timeline_storage_migration_native_test.dart. Interface: manual/push bounded-candidate pipeline invokes verifier with full device app, source SHA, version/build, source entitlements and output directory. Artifact includes IPA, manifest and entitlement handoff; no secrets/signing/upload actions.

- [x] Test-first RED for absent pipeline/invalid device/version/required metadata; implement minimum source/IPA verification and production build workflow; GREEN and Python syntax/YAML/command checks.
- [ ] macOS release --no-codesign plus production URLs/in-app-update/performance defines; no-tree-shake-icons; Ruby permission hook and real binary gates, full plugin/native/asset checks; ditto Payload packing preserves modes/symlinks.
- [ ] Separate simulator job uses only scanner exclusion, committed IntegrationTest binding wrapper under integration_test around existing migration suite plus iOS platform guard, and existing SQLCipher/WAL+Keychain integration targets; capture real exits and synthetic limitations. Flutter3.44.9 source only recognizes integration_test-prefixed paths; do not use external RUNNER_TEMP Flutter-test targets as native proof.
- [x] SPEC then QUALITY review before CI push; declare tested inputs and exact source commit. Keep test and build output identity separate.

## Task 3: Build, verify and deliver (root)

- [ ] Push only reviewed candidate branch to configured repo and bind exact queued run/head; run native jobs through completion with actual exits/attempt identity.
- [ ] Download exact successful unsigned artifact via authenticated HTTPS; validate ZIP CRC/Payload/plist/native/manifest SHA and production source/lock/config. No public finished-package redownload or production publication.
- [ ] Ordered final artifact reviews; record IPA path/bytes/SHA, unsigned status, entitlement handoff and runtime/phone/enterprise-upgrade gaps.
- [ ] Update task/index and primary document mirror preserving unrelated WIP; provide actual IPA file and signing handoff.
