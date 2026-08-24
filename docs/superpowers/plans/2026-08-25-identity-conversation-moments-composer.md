# Identity, Conversation, Moments, and Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task by task with review checkpoints.

**Goal:** Make identity changes observable across the Flutter app, apply the approved conversation naming rules, replace the Moments owner placeholder with the signed-in profile, and rebuild the Moments composer and visibility flow in the approved WeChat-style UI.

**Architecture:** Keep business APIs authoritative for profile, contact remark, and avatar data. Introduce one application-scoped observable identity cache shared by Messages, Contacts, and Moments. Isolate conversation display derivation in pure presentation helpers, while group-room navigation and group-info naming remain explicit context-specific rules. Split composer visibility selection into dedicated routes and preserve selections as local draft state until publishing succeeds.

**Tech Stack:** Flutter/Dart, Provider-free `ChangeNotifier`/`ListenableBuilder`, Matrix Flutter SDK, `flutter_test`, REST business API, Figma delivery registry, PowerShell 7, Android SDK/ADB, Docker Compose.

---

## Task 1: Make identity data observable and safely refreshable

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/chat_identity_cache.dart`
- Modify: `apps/mobile_flutter/lib/features/contacts/contact_models.dart`
- Test: `apps/mobile_flutter/test/features/matrix/chat_identity_cache_test.dart`
- Test: `apps/mobile_flutter/test/features/contacts/contact_models_test.dart`

**Step 1: Write failing cache tests**

Add tests proving that:

- `applyUpdatedContact` replaces the matching contact, refreshes user-id lookup, and notifies listeners exactly once.
- `refresh` performs a new profile/contact load after the initial preload rather than returning the memoized future.
- refresh failure retains the last successful snapshot and exposes a structured, non-sensitive error log path.
- `ContactDetails.toSummary()` preserves `remark`, `nickname`, `username`, and avatar independently.

**Step 2: Run the focused tests and confirm the intended failure**

```powershell
pwsh.exe -NoProfile -Command '$utf8 = [System.Text.UTF8Encoding]::new($false); [Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8; $env:PYTHONUTF8="1"; $env:PYTHONIOENCODING="utf-8"; Set-Location -LiteralPath "D:\pythonProject\outsource\StarChat\apps\mobile_flutter"; flutter test test/features/matrix/chat_identity_cache_test.dart test/features/contacts/contact_models_test.dart'
```

Expected: FAIL because the cache is not observable/refreshable and the conversion helper is absent.

**Step 3: Implement the minimum cache contract**

- Make `ChatIdentityCache` extend `ChangeNotifier`.
- Keep one immutable successful snapshot at a time.
- Retain `preload()` for initial coalescing and add a real `refresh()` path.
- Add `applyUpdatedContact(ContactSummary contact)` for immediate in-memory propagation.
- Persist successful snapshots when storage is available; never discard the in-memory update when persistence fails.
- Log operation, contact/user identifiers in redacted form, exception type, and stack trace; never log tokens or message bodies.
- Add `ContactDetails.toSummary()` as the single details-to-cache mapping.

**Step 4: Re-run focused tests**

Expected: PASS.

**Step 5: Commit**

```powershell
git add -- apps/mobile_flutter/lib/features/matrix/chat_identity_cache.dart apps/mobile_flutter/lib/features/contacts/contact_models.dart apps/mobile_flutter/test/features/matrix/chat_identity_cache_test.dart apps/mobile_flutter/test/features/contacts/contact_models_test.dart
git commit -m "feat(identity): make contact identity updates observable"
```

## Task 2: Propagate friend remark edits to Contacts and Messages immediately

**Files:**
- Modify: `apps/mobile_flutter/lib/features/home/app_home_page.dart`
- Modify: `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`
- Modify: `apps/mobile_flutter/lib/features/contacts/contact_profile_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Test: `apps/mobile_flutter/test/features/contacts/contacts_page_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/matrix_home_page_test.dart`

**Step 1: Write failing widget tests**

Prove that saving a new remark:

- updates the visible Contacts row without recreating the app;
- updates an already-mounted direct-message row;
- falls back to nickname when the saved remark is blank;
- leaves old values visible and reports the failure if the API save fails.

**Step 2: Run tests and confirm red state**

Run the two focused widget-test files and confirm the old memoized/list-local state causes failure.

**Step 3: Wire one shared cache through application scope**

- Pass the existing app-owned cache into Contacts, Messages, and later Moments.
- On successful contact edit, convert the returned `ContactDetails` to a summary and call `applyUpdatedContact` before the route settles.
- Make mounted lists rebuild from cache notifications rather than relying on app restart or route reconstruction.
- Keep API-save success as the boundary: do not publish optimistic identity data before the server accepts it.

**Step 4: Re-run tests and commit**

```powershell
git add -- apps/mobile_flutter/lib/features/home/app_home_page.dart apps/mobile_flutter/lib/features/contacts/contacts_page.dart apps/mobile_flutter/lib/features/contacts/contact_profile_page.dart apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart apps/mobile_flutter/test/features/contacts/contacts_page_test.dart apps/mobile_flutter/test/features/matrix/matrix_home_page_test.dart
git commit -m "fix(identity): refresh remarks across contacts and messages"
```

## Task 3: Centralize conversation titles and subtitles

**Files:**
- Create: `apps/mobile_flutter/lib/features/matrix/conversation_presentation.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/chat_identity_cache.dart`
- Test: `apps/mobile_flutter/test/features/matrix/conversation_presentation_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/matrix_home_page_test.dart`

**Step 1: Write pure failing tests for every display rule**

Cover:

- direct title: `remark → nickname`, with username only as defensive last-resort data;
- group list title: every selected member including the signed-in user, resolved as `remark → nickname`, joined with `、`;
- group subtitle with unread: `[3条]项目小李：消息内容`;
- group subtitle without unread: `项目小李：消息内容`;
- redaction with unread: `[3条]项目小李撤回了一条消息`;
- sender fallback: remark, nickname, Matrix display name, Matrix-ID localpart;
- true system events use an explicit localized system summary;
- the existing unread badge remains independent from subtitle text.

**Step 2: Run tests and confirm failure**

Expected: FAIL because rows currently use Matrix room display name and raw `lastEvent.text`.

**Step 3: Implement pure presentation helpers**

- Accept already-fetched identity/member/event inputs; never query tables or mutate Matrix state.
- Keep message bodies out of logs.
- Distinguish redaction, ordinary sender messages, and actual system events.
- Use the shared cache for business identity lookup and Matrix member data only for documented fallbacks.

**Step 4: Integrate helpers into conversation rows**

- Replace direct and group row title derivation.
- Replace group subtitle derivation with the strict format.
- Preserve the current unread badge and timestamp behavior.

**Step 5: Run tests and commit**

```powershell
git add -- apps/mobile_flutter/lib/features/matrix/conversation_presentation.dart apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart apps/mobile_flutter/lib/features/matrix/chat_identity_cache.dart apps/mobile_flutter/test/features/matrix/conversation_presentation_test.dart apps/mobile_flutter/test/features/matrix/matrix_home_page_test.dart
git commit -m "fix(messages): apply approved conversation display rules"
```

## Task 4: Apply context-specific group naming rules

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/group_room_navigation_title.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_chat_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/group_chat_qr_page.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_room_navigation_title_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_chat_info_controller_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/group_chat_controller_test.dart`

**Step 1: Write failing tests**

Assert:

- chat navigation is always `群聊(人数)` regardless of explicit room name;
- blank explicit Matrix room name is shown as `未命名` on Group Info and QR details;
- an explicit custom group name remains visible on Group Info;
- new-group creation still exposes the optional name field and sends an empty name when omitted;
- no UI output contains `Group with`.

**Step 2: Run focused tests and confirm failure**

**Step 3: Implement minimal context rules**

- Navigation helper ignores the custom name and uses member count.
- Info controller reads explicit `room.name`, not synthesized localized display name.
- Info/QR views map blank explicit names to `未命名`.
- Do not change room membership, encryption, or creation behavior.

**Step 4: Re-run tests and commit**

```powershell
git add -- apps/mobile_flutter/lib/features/matrix/group_room_navigation_title.dart apps/mobile_flutter/lib/features/matrix/matrix_chat_page.dart apps/mobile_flutter/lib/features/matrix/group_chat_info_controller.dart apps/mobile_flutter/lib/features/matrix/group_chat_info_page.dart apps/mobile_flutter/lib/features/matrix/group_chat_qr_page.dart apps/mobile_flutter/test/features/matrix/group_room_navigation_title_test.dart apps/mobile_flutter/test/features/matrix/group_chat_info_controller_test.dart apps/mobile_flutter/test/features/matrix/group_chat_controller_test.dart
git commit -m "fix(groups): separate list chat and info naming"
```

## Task 5: Replace the Moments owner placeholder with the signed-in profile

**Files:**
- Modify: `apps/mobile_flutter/lib/features/home/app_home_page.dart`
- Modify: `apps/mobile_flutter/lib/features/discovery/discovery_page.dart`
- Modify: `apps/mobile_flutter/lib/features/profile/profile_page.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Test: `apps/mobile_flutter/test/features/moments/moments_page_test.dart`

**Step 1: Write failing widget tests**

Assert that the cover overlay renders current `ProfileData.nickname` and avatar, never the fixed `畅聊朋友圈` string, and shows the standard avatar fallback plus a structured image error when loading fails.

**Step 2: Run the Moments test and confirm failure**

**Step 3: Inject and render the shared identity snapshot**

- Pass the app-owned cache through every Moments entry point.
- Use only the current business profile for the owner overlay.
- Resolve relative avatar URLs through the existing business API/media URL policy.
- Keep cover expansion/change-cover behavior intact.

**Step 4: Re-run tests and commit**

```powershell
git add -- apps/mobile_flutter/lib/features/home/app_home_page.dart apps/mobile_flutter/lib/features/discovery/discovery_page.dart apps/mobile_flutter/lib/features/profile/profile_page.dart apps/mobile_flutter/lib/features/moments/moments_page.dart apps/mobile_flutter/test/features/moments/moments_page_test.dart
git commit -m "fix(moments): render the signed-in owner profile"
```

## Task 6: Deliver the WeChat-style composer and visibility flow with Figma parity

**Files:**
- Create: `apps/mobile_flutter/lib/features/moments/moment_composer_page.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moment_visibility_page.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moment_visibility_people_page.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `docs/figma/chatflow-ui-delivery-registry.json`
- Modify: `docs/figma/chatflow-ui-parity-ledger.md`
- Test: `apps/mobile_flutter/test/features/moments/moment_composer_page_test.dart`
- Test: `apps/mobile_flutter/test/features/moments/moment_visibility_page_test.dart`
- Test: `apps/mobile_flutter/test/features/moments/moment_visibility_people_page_test.dart`

**Step 1: Check for live Figma write capability**

Search the available tools for Figma read/write support. If available, inspect the existing Moments nodes, update the same page/components, capture node URLs and screenshots, and perform drift comparison. If unavailable, do not invent remote node IDs: update the repository registry and parity ledger with the approved browser artifact, implementation mapping, and explicit tool limitation.

**Step 2: Write failing UI and state tests**

Cover:

- strict WeChat-style compose hierarchy, text/media area, publish action, and only `谁可以看` / `添加链接` rows;
- `公开` and `私密` in the first group;
- a visual gap before chevron submenu rows `只给谁看` / `不给谁看`;
- submenu subtitle `选择标签或朋友`;
- 标签/朋友 tabs, search, multi-select, selected count, and complete;
- Back discards uncommitted submenu edits; Complete returns them;
- visibility/load/publish failures retain user content and selections with an actionable error;
- accessibility labels, keyboard insets, and small-screen layout.

**Step 3: Implement the pages and state flow**

- Extract composer code from the oversized Moments page.
- Keep `公开`/`私密` mutually exclusive.
- Treat `只给谁看`/`不给谁看` as secondary routes, not radio rows.
- Use contacts/tags from business API/cache; never Matrix member display data for audience rules.
- Preserve current draft until publish succeeds; publish through the existing Moments API contract.

**Step 4: Update design delivery records**

- Register the composer, parent visibility page, and people/tag selector.
- Record Flutter file/widget/test mappings and the approved visual artifact path.
- Record live Figma evidence only when actually obtained.

**Step 5: Run tests and commit**

```powershell
git add -- apps/mobile_flutter/lib/features/moments apps/mobile_flutter/test/features/moments docs/figma/chatflow-ui-delivery-registry.json docs/figma/chatflow-ui-parity-ledger.md
git commit -m "feat(moments): rebuild composer and audience flow"
```

## Task 7: Run specification, quality, security, and regression verification

**Files:**
- Create: `docs/verification/2026-08-25-identity-conversation-moments-composer.md`
- Create artifacts only below: `docs/verification/artifacts/2026-08-25/identity-conversation-moments-composer/`

**Step 1: Run formatting and static checks**

```powershell
pwsh.exe -NoProfile -Command '$utf8 = [System.Text.UTF8Encoding]::new($false); [Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8; Set-Location -LiteralPath "D:\pythonProject\outsource\StarChat\apps\mobile_flutter"; dart format --output=none --set-exit-if-changed lib test; flutter analyze'
```

**Step 2: Run focused and full Flutter tests**

```powershell
pwsh.exe -NoProfile -Command '$utf8 = [System.Text.UTF8Encoding]::new($false); [Console]::InputEncoding = $utf8; [Console]::OutputEncoding = $utf8; $OutputEncoding = $utf8; Set-Location -LiteralPath "D:\pythonProject\outsource\StarChat\apps\mobile_flutter"; flutter test'
```

**Step 3: Run repository verification when present**

```powershell
pwsh.exe -NoProfile -File scripts/verify.ps1
```

**Step 4: Perform two ordered reviews**

First compare every implemented behavior against the approved specification. Then review quality/security: business identity authority, E2EE boundary, sensitive logging, failure retention, async lifecycle, image errors, and regressions.

**Step 5: Record evidence and commit**

Include commands, exit codes, test counts, screenshots/artifact hashes, known environment limitations, and exact commit IDs. Do not copy secrets or message bodies into evidence.

## Task 8: Build, deploy, install, and verify the release

**Files:**
- Modify only if backend contract changed: deployment manifests/runbooks under their existing locations
- Add release evidence below: `docs/verification/artifacts/2026-08-25/identity-conversation-moments-composer/`

**Step 1: Inspect the final diff and public environment**

- Confirm whether any server-side code/config changed.
- Check `ssh -p 23421 root@207.56.8.8` health and `/opt/starchat` deployment state.
- If the diff is Flutter-only, do not restart unrelated backend containers; record backend health and unchanged contract.
- If backend code changed, sync only reviewed files, run the relevant migration/compose validation, deploy explicit image versions, and verify health/rollback.

**Step 2: Build the public-server APK**

Use the repository’s existing public API/Matrix build defines. Capture the exact command, exit code, APK SHA-256, and source commit. Never embed credentials.

**Step 3: Resolve one emulator and install deterministically**

- Run `adb devices -l` and require exactly one authorized target or select the explicitly documented emulator serial.
- Install with `adb -s <serial> install -r <apk>`.
- Verify installed package/version and launch the application.

**Step 4: Verify all approved behaviors on the emulator**

With non-sensitive test accounts/data, capture screenshots/log excerpts for:

- Moments owner avatar/nickname;
- immediate remark refresh in Contacts and Messages;
- direct and group titles/subtitles, unread prefix and badge, redaction summary;
- group list/chat/info naming distinctions;
- composer and all visibility routes, search, selection, Back/Complete behavior;
- cover, like, comment, avatar, and existing Moments regressions.

Do not perform destructive production data operations. Redact Matrix IDs, tokens, and personal content in stored evidence.

**Step 5: Final release checks and synchronization**

- Re-run server health after installation verification.
- Run `git status --short`, `git diff --check`, and verify no root-level artifacts/secrets.
- Commit verification evidence.
- Push the current branch to its configured remote. If authorization still returns HTTP 403, preserve the local commits and report the exact remote/account blocker without claiming a successful push.

---

## Completion criteria

- Every display rule in the approved specification has a test and emulator evidence.
- Remark changes propagate through the shared observable cache after server save, without app restart.
- No fixed `畅聊朋友圈` or synthesized `Group with` output remains in relevant UI paths.
- Figma is updated and evidenced when a write-capable tool is available; otherwise the repository parity records explicitly document the limitation without fabricated links.
- Public services remain healthy, the new APK is installed and launched on the emulator, and all release evidence is stored only under `docs/verification/`.
