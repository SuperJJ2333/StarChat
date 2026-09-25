# 群聊、朋友圈、钱包与 Mi 6 Debug Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Track red and green results in this task's verification record.

**Goal:** Deliver the eight user-requested mobile UI and media changes in a data-preserving MI 6 Debug upgrade.

**Architecture:** Continue the exact source candidate used for the installed 2168 Debug package in `.worktrees/online-room-refresh`, retaining its existing uncommitted fixes. Keep announcement content in Matrix encrypted room events and encrypted attachments; public room state stores only the selected event ID. Keep Moments media in its existing upload/player/account cache interfaces and wallet pricing as display copy only. Synchronize the HTML demo and UI registry with the Flutter result.

**Tech Stack:** Flutter/Dart, Matrix SDK, existing Moments business API and media cache, HTML demo, Android Flutter/Apktool/zipalign/apksigner, ADB.

---

### Task 1: 群公告提示与编辑

**Files:** `apps/mobile_flutter/lib/features/matrix/room_page.dart`, `group_announcement_page.dart`, relevant `apps/mobile_flutter/test/features/matrix/group_announcement*_test.dart` and room tests.

- [x] Add focused widget tests: pale yellow notice; right dismiss action suppresses the current announcement across page return/restart and a new announcement reappears; no banner for empty content. Confirm RED.
- [x] Add editor tests: continuous multiline text input, no “添加文字” action, image icon opens the app album with video entries hidden and image/GIF entries available; member remains read-only. Confirm RED.
- [x] Implement with existing announcement ID/version and album gateway; preserve publication permissions and previous announcement content. Confirm GREEN.

### Task 2: 群信息与群管理

**Files:** `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`, corresponding group information widget tests.

- [x] Add RED tests for a single-line 12-character name field, owner transfer entry, absence of the obsolete group-management hint, and a filled destructive group dissolution button.
- [x] Implement within the existing Matrix owner/role controller. Confirm GREEN, including permission and failure states.

### Task 3: 朋友圈媒体与警告

**Files:** `apps/mobile_flutter/lib/features/moments/moment_composer_page.dart`, Moments media/player widgets, `apps/mobile_flutter/lib/ui/moments/moment_media_cache.dart`, and focused Moments tests.

- [x] Add RED tests for GIF and video selection, upload, saved post rendering and playback, media cache reuse and failure handling, plus warning appearance matching the recharge/withdraw component.
- [x] Reuse the existing album, video player and account-scoped media cache APIs. Preserve server MIME/size validation and no video display where the album is opened for announcements. Confirm GREEN.

### Task 3a: 朋友圈上传完成缓存标识合同

**Files:** `services/business-api/app/api/moments.py`, `tests/business_api/moments/test_moment_video_media.py`, `packages/api-contracts/openapi/liuhetong-v1.yaml`.

- [x] Add RED API assertion that `complete_upload.media_cache_key` is a 64-character stable digest equal to the published feed `video_cache_keys[0]`; observed missing field failure.
- [x] Expose the existing Moments reference digest for `media://{object_key}` after authenticated completion, regenerate OpenAPI, and confirm GREEN.
- [x] Run adjacent Moments API tests and deployment candidate protocol gates. Any production deployment must use the current running image as a base, preserve the refresh protocol guard and all unrelated files/services.

### Task 4: 钱包文案

**Files:** `apps/mobile_flutter/lib/features/wallet/manual_wallet_page.dart`, `apps/mobile_flutter/test/features/wallet/manual_wallet_navigation_test.dart`.

- [x] Change the focused widget expectation to `仅支持 TRON 网络 · 1 点钻 = 1 CNY · 手续费 0` and confirm RED.
- [x] Change the wallet overview label only, then confirm GREEN. Do not alter fee calculations, quotes, API contracts or ledger behavior.

### Task 5: HTML demo and registry

**Files:** `frontend/src/screens/messaging.js`, `frontend/src/screens/moments.js`, wallet demo screen, `frontend/src/catalog/screens.js`, `packages/ui-contracts/changliao-component-registry.json`, related demo tests.

- [x] Add/update catalog variants for announcement notice/editor, group controls, Moments GIF/video and warning, wallet copy. Update mapped props/states/tokens in the registry.
- [x] Run `python scripts/verify_ui_contract.py` and `npm test` from `frontend/`; inspect the resulting demo screen.

### Task 6: 集成验证与设备交付

**Files:** `apps/mobile_flutter/pubspec.yaml`, `docs/workflow/tasks/2026-09-24-group-moments-wallet-debug.md`, `docs/verification/2026-09-24-group-moments-wallet-debug.md`, task-only artifacts below `docs/verification/artifacts/2026-09-24/`.

- [x] Preflight toolchain, source/input identities, disk and MI 6 online state. Advance version to the next unused Debug code.
- [x] Run focused Flutter tests, analyzer, relevant full Flutter test gate, UI contract/frontend tests and applicable `scripts/verify.ps1` gate, reusing identical-input evidence only as the workflow allows. Perform specification review before quality/security review.
- [x] Build ARM64 Debug with the current HTTPS Dart defines, fully rebuild with Apktool 2.12.1, zipalign and sign using the existing user-tested identity. Verify class/asset/manifest equivalence, ABI, version and certificate.
- [x] Check device installed package/version/signature; use only data-preserving `adb install -r`. Verify device APK SHA, first-install time unchanged, version and launch. Do not publish production app links or update prompts.

**Acceptance:** Tests and evidence prove all eight requested outcomes; final report separates source, built/installed package, and still-pending manual UI feedback.
