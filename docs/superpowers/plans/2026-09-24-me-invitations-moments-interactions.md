# “我”页导航、邀请历史与朋友圈互动实施计划

> **For agentic workers:** Execute bounded tasks with test-first RED/GREEN evidence. Complete specification review before quality/security review. The user's precise 2026-09-24 request authorizes this plan; existing approved product specifications remain in force.

**Goal:** Make every “我” secondary route cover the bottom Tab safely, show actual invitation history, enforce visible-character profile limits, and deliver a private, paged “我的朋友圈” interaction inbox with distinct reminders.

**Architecture:** Reuse the root `Navigator` for all “我” secondary routes, then clear authenticated root routes on session loss. Reuse existing invitation history and Moments notification tables and public application gateways. Keep the Moments detail/media visibility policy authoritative on every open; historical notifications may remain visible with generic summaries after access is revoked. Count profile characters as Unicode extended grapheme clusters on both client and server. The HTML demo is the UI source of record; Figma synchronization is retired.

**Tech Stack:** Flutter/Dart `characters`, FastAPI/SQLAlchemy/PostgreSQL, existing business API and Moments module, HTML design demo, Android ARM64 Debug/ADB.

**Working tree:** `.worktrees/online-room-refresh`, preserving the previous 0.4.10/2169 candidate and all unrelated edits. Do not edit the same file concurrently.

## File ownership and interfaces

| Task | Exclusive source ownership | Shared interface |
| --- | --- | --- |
| 1–2 navigation/profile | `apps/mobile_flutter/lib/app_home.dart`, `session_gate.dart`, `features/profile/profile_page.dart`, `features/profile/profile_controller.dart`, focused navigation/profile widget tests | `PersonalMomentsPage` accepts self `userId`, `displayName`, and a notification-changed callback; `BusinessApiClient` exposes existing unread count. |
| 3 invitation route proof | New `apps/mobile_flutter/test/features/profile/invite_route_history_test.dart` | Task 1 adds `historyGateway: widget.api` in `app_home.dart`. |
| 4 profile API | `services/business-api/app/api/profile.py`, `app/api/identity.py`, `app/modules/identity/profile.py`, `app/modules/identity/registration.py`, identity model and new additive migration, API dependency manifests, focused identity/registration tests | Root regenerates OpenAPI after all backend edits. |
| 5–6 Moments | `services/business-api/app/modules/moments/service.py`, `app/api/moments.py`, `apps/mobile_flutter/lib/features/moments/`, `apps/mobile_flutter/lib/core/business_api_client.dart`, focused Moments tests | Task 1 owns the “我” entry and badge; Moments page supplies its own “更多” route and callback. |
| 7–8 integration | `frontend/`, UI registry/tests, OpenAPI, ADR, plan/task/verification docs, Android build/deployment artifacts | Wait for source owners to freeze before full gates/build/deploy. |

## Task 0: Protected contract decision

**Files:** `docs/adr/0085-profile-visible-character-limits.md`, this plan, task and verification records.

- [x] Record the user-approved 12/20 grapheme limit, old 64/140 code-point contract, Unicode segmentation choice, existing longer value handling, widening-only DB migration and guarded rollback. Obtain domain review and Quality/Security review before implementing the profile API change.
- [x] Record current baseline and source ownership in `docs/workflow/tasks/2026-09-24-me-invitations-moments-interactions.md`. Use an isolated artifact folder below `docs/verification/artifacts/2026-09-24/`.

## Task 1: Secondary route coverage and session lifecycle

**Files:** `apps/mobile_flutter/lib/app_home.dart`, `apps/mobile_flutter/lib/features/profile/profile_page.dart`, `apps/mobile_flutter/lib/session_gate.dart`; test `apps/mobile_flutter/test/features/profile/profile_secondary_navigation_test.dart`, `apps/mobile_flutter/test/session_gate_test.dart`.

- [x] Write failing widget tests covering identity card/个人信息, 朋友圈, 点钻, 钱包, 设置, QR code and 邀请码 entry; assert Tab absent and bottom content uses safe area on every child. Test visible back button, system back, edge-swipe and route removal; after return, Tab reappears and changes primary page normally. Test nested settings/点钻账单/邀请码 and login/session replacement while a child is open. Run focused tests and record the intended RED failures.
- [x] Push each top-level “我” child through `Navigator.of(context, rootNavigator: true)` using normal `MotionPageRoute` so gesture pop is available. Ensure captured callbacks for 点钻账单, 邀请码 and QR code use the root route. After async self-ID lookup, recheck `mounted`, API session epoch and account key before pushing.
- [x] On authenticated/offline-authenticated → unauthenticated/fatal session transition, pop authenticated root routes before the existing logout dialog; preserve offline↔online and initial loading behavior. Re-run tests to GREEN.

## Task 2: Profile input and save limits

**Files:** `apps/mobile_flutter/lib/features/profile/profile_page.dart`, `profile_controller.dart`; test `apps/mobile_flutter/test/features/profile/profile_grapheme_limit_test.dart`, adjacent profile save tests.

- [x] Write RED tests for 12-character nickname and 20-character signature using Chinese, ASCII, digits, punctuation and ZWJ emoji; assert live `n/12`, `n/20`, truncation/refusal on overflow, closeable exact dialogs “昵称最多支持12个字符” and “个性签名最多支持20个字符”, and failed save for an over-limit preloaded value or direct controller call.
- [x] Use Dart `characters` for grapheme counting and an input formatter preserving valid selection/composition. Show at most one overflow dialog per edit burst, retaining the valid draft. Revalidate trimmed changed fields before calling the profile gateway; submit only changed nickname/signature so an unrelated edit is not blocked by a historical long value. Keep failed-save drafts. Run focused tests to GREEN.

## Task 3: Invitation history entry

**Files:** `apps/mobile_flutter/lib/app_home.dart` (Task 1 owner only); new test `apps/mobile_flutter/test/features/profile/invite_route_history_test.dart` (Task 3 owner).

- [x] Build a failing real-route widget test: navigate 个人信息 → 邀请码, require authenticated `GET /invitations/history?limit=20&offset=0`, a visible nickname, 畅聊号 and `YYYY-MM-DD HH:mm` time. Cover next page and explicit empty state. The current page remains `invite-history-idle`, establishing RED.
- [x] Task 1 owner injects `historyGateway: widget.api` into `InviteCodeController` and retains existing descending API order, paging, load failure/retry and account isolation. Run route test plus existing controller/API invitation suites to GREEN. No backend or migration change is planned for this task.

## Task 4: Server-authoritative profile grapheme limits

**Files:** `services/business-api/app/api/profile.py`, `app/api/identity.py`, `app/modules/identity/profile.py`, `app/modules/identity/registration.py`, user model, `migrations/versions/0088_profile_grapheme_limits.py`, `pyproject.toml`, `requirements.lock`; tests `tests/business_api/identity/test_profile_api.py`, registration and migration tests.

- [x] Write RED profile and registration API tests for 12/20 accepted and 13/21 rejected grapheme clusters, including repeated family/skin-tone emoji whose code-point length exceeds legacy VARCHAR limits; prove an unrelated avatar update does not silently mutate stored profile values. Cover email eligibility preflight, actual registration, explicit nickname and missing nickname default. Confirm error codes and field-specific messages.
- [x] Add a pinned Unicode extended-grapheme segmentation dependency and one shared identity validator. Keep a generous 512-code-point raw request guard with OpenAPI `x-graphemeMaxLength: 12/20`; validate only submitted profile fields. Registration must normalize identically before eligibility/idempotency hashing, reject explicit nonempty over-limit nickname, preserve empty-string fallback and whitespace rejection, and derive an at-most-12-grapheme default from username; test OTP fixed nickname. Permit exact actor/scope/key/hash read-only replay of old completed requests before new validation, never a new legacy write. Widen the two database columns without dropping data; migration downgrade must refuse truncating existing values. Run focused API and migration tests to GREEN, then regenerate OpenAPI in Task 8.

## Task 5: Moments interaction contract and privacy

**Files:** `services/business-api/app/modules/moments/service.py`, `app/api/moments.py`; tests under `tests/business_api/moments/`.

- [x] Write RED tests: friend comment on own post creates COMMENT notification; reply to one's comment or reply creates REPLY notification once (including post-author overlap), while own actions do not alert self. Prevent like/comment on unpublished moments. Validate idempotent replay.
- [x] Write RED tests for recipient-only notification access, descending stable pagination, unread counts, current safe actor/type/content/source/time projection, and retained generic historical rows after deletion, audience revocation or 3-day/1-month/6-month expiry. No private body/media or cross-account row may leak. Clicking target uses the existing detail visibility check and fails closed.
- [x] Reuse `moment_notifications` and `comment_id`; add an authenticated paged response (`items`, `next_cursor`) with a stable `(created_at,id)` cursor and bounded limit. Preserve old clients that read `items`. Emit existing audited/outbox comment event without placing body text in push payload. Run focused Moments backend tests to GREEN.

## Task 6: “我的朋友圈” and interaction UI

**Files:** `apps/mobile_flutter/lib/features/moments/personal_moments_page.dart`, `moment_detail_page.dart`, `moment_models.dart`, new interaction list/controller under that folder, `apps/mobile_flutter/lib/core/business_api_client.dart`; focused Moments Flutter tests.

- [x] Write RED tests showing that “我→朋友圈” contains only the current user's `PUBLISHED` posts, not friends or ad cards; own unpublished states must not masquerade as published or offer detail/interaction actions. Test the self page “更多” button and distinct unread badge on the “我” entry.
- [x] Write RED tests for interaction list loading/empty/error/more pages; each row shows actor, 评论/回复 wording, interaction/source excerpt and time. Clicking first fetches authorized detail, then pushes and scrolls/highlights `comment_id`; 403/404/deleted/expired never flashes cached content and instead shows “该内容不可查看” (or safe expiry-specific text). Account switch clears badge/inbox state and ignores late responses.
- [x] Add typed notification DTO and paged gateway. Use `GET /moments/users/{self}` and explicit published-only presentation for the “我” route; keep existing feed from “发现”. Reuse Moments media/cache and detail visibility policy, mark notification read only for the authenticated recipient. Run focused Flutter tests and analyze to GREEN.
- [x] Keep notifications separate from Matrix conversations. Use the existing in-app unread count/badge and Moments notification entry; no new system push route is required because current business Moments events have no push consumer. Any future push payload must contain only opaque IDs and generic metadata.

## Task 7: HTML demo and UI registry

**Files:** `frontend/src/screens/profile.js`, `moments.js`, `frontend/src/catalog/screens.js`, `frontend/src/styles/primitives.css`, fixtures and tests, `packages/ui-contracts/changliao-component-registry.json`, `tests/mobile/test_ui_component_registry.py`.

- [x] First add failing HTML tests for child pages without Tab, invitation history/empty/more, visible-character edit counter/overflow dialog, self-only Moments, interaction inbox/detail failure and separate badge.
- [x] Add reviewable screens and real demo navigation/states using existing tokens and components. Update the registry feedback contract and exact screen count; avoid Figma files. Run `npm test` and `python scripts/verify_ui_contract.py` to GREEN and visually inspect representative 393×852 screens.

## Task 8: Integrated verification and delivery

**Files:** `packages/api-contracts/openapi/liuhetong-v1.yaml`, `apps/mobile_flutter/pubspec.yaml`, task and verification records, task-only artifacts under `docs/verification/artifacts/2026-09-24/`.

- [x] Freeze source owners; first conduct specification-compliance review, then independent domain and Quality/Security review (including privacy, session isolation, navigation and migration). Fix findings with focused RED/GREEN proofs.
- [x] Run focused tests, Flutter analyzer and affected full Flutter gate, frontend/UI contract, profile/invitation/Moments backend suites, OpenAPI export check, migration upgrade/rollback/restore and `pwsh -NoProfile -File scripts/verify.ps1` after environment preflight. Reuse identical-input prior evidence only under the mobile workflow's change-impact rule; record real exit codes and existing failures separately.
- [x] If backend changes are needed for the current MI 6 integration, prepare and release the minimal API/worker delta using the production runbook, current live image/schema snapshot, private isolated DB restoration, HTTPS/auth checks and documented rollback. Never change unrelated containers or financial state.
- [x] Build the next ARM64 Debug from source, perform the required conventional Apktool 2.12.1 rebuild, zipalign and fixed user-tested signing, verify content/manifest/signature, then use `adb install -r` on the MI 6 without clearing data. Verify installed SHA, version, signer, first-install time, launch and crash buffer. Record manual behavior awaiting user feedback.

**Acceptance:** All five user requirements are demonstrated through existing entrances, returns and account transitions; historical alerts remain but unauthorized content never opens; the Android candidate and backend state are explicitly distinguished from source-only changes.
