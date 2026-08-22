# UI Rules Application Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the approved activation-code transaction ordering, avatar cache policy, and fixed chat/tab background tokens to the Flutter client and identity service.

**Architecture:** Registration retains one database transaction but defers invitation consumption until the user, email-verification challenge, outbox event, and idempotency result have been flushed successfully. A dedicated avatar cache facade configures Flutter's LRU image cache and a versioned, 30-day disk cache; `UserAvatar` is its only network-image consumer. Named immutable color tokens are consumed explicitly by chat and tab-root page scaffolds.

**Tech Stack:** Python 3.12, SQLAlchemy, Flutter/Dart, flutter_cache_manager 3.4.1, cached_network_image 3.4.1, flutter_test, pytest, PowerShell 7.

---

## File map

- Modify: `services/business-api/app/modules/identity/registration.py` — defer invitation consumption to the final persisted registration stage.
- Modify: `tests/business_api/identity/test_registration.py` — prove failed registration does not consume an invitation.
- Modify: `apps/mobile_flutter/pubspec.yaml`, `apps/mobile_flutter/pubspec.lock` — pin avatar-cache dependencies.
- Create: `apps/mobile_flutter/lib/ui/foundation/avatar_cache.dart` — cache key, 200-entry LRU configuration, 30-day disk manager, and precise invalidation API.
- Modify: `apps/mobile_flutter/lib/ui/components/user_avatar.dart` — route remote avatars through the cache facade.
- Modify: `apps/mobile_flutter/lib/features/profile/profile_controller.dart` — invalidate old and replacement avatar cache entries after a successful mutation.
- Modify: `apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart` — named fixed chat/tab colors.
- Modify: `apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart` — apply exact chat navigation/page colors and message-tab root color.
- Modify: `apps/mobile_flutter/lib/app_home.dart`, `apps/mobile_flutter/lib/features/contacts/contacts_page.dart`, `apps/mobile_flutter/lib/features/discovery/discovery_page.dart`, `apps/mobile_flutter/lib/features/profile/profile_page.dart` — apply tab-root background to all four root page scaffolds.
- Modify: `apps/mobile_flutter/test/ui/wechat_theme_test.dart`, `apps/mobile_flutter/test/ui/wechat_components_test.dart`, `apps/mobile_flutter/test/ui/messaging_surfaces_test.dart`, `apps/mobile_flutter/test/features/profile/profile_controller_test.dart` — focused token/cache/mutation behavior assertions.
- Modify: `docs/verification/2026-08-19-registration-server-activation.md` — literal verification evidence.

### Task 1: Protect activation-code state on failed registration

- [x] Add a failing registration test that forces the registration outbox flush to fail after a valid invitation is supplied, then asserts the invitation `use_count` remains zero.
- [x] Run the focused test and record its red failure.
- [x] Move `consume_in_session()` after user, challenge, outbox, and idempotency objects are flushed, inside the existing transaction and before commit.
- [x] Run the focused test and full identity-registration test module.

### Task 2: Define and test fixed colors

- [x] Add failing token assertions for `chatNavigationBackground=#F7F7F7`, `chatPageBackground=#EDEDED`, and `tabRootPageBackground=#EDEDED`.
- [x] Add the three named tokens and replace the direct chat-page color branches with fixed tokens; set the `CupertinoNavigationBar.backgroundColor` explicitly.
- [x] Apply `tabRootPageBackground` to message, contacts, discovery, and profile root `CupertinoPageScaffold`s.
- [x] Run the focused Flutter UI tests.

### Task 3: Implement cache-backed chat avatars

- [x] Add failing pure and widget tests for a stable user/version/size cache key, 30-day policy, 200-entry LRU configuration, and a cached remote `ImageProvider`.
- [x] Pin `cached_network_image` and `flutter_cache_manager`; run `flutter pub get`.
- [x] Implement `AvatarCache` with 30-day `CacheManager` configuration, version-sensitive key generation, cached provider construction, and user-key precise invalidation.
- [x] Replace `Image.network` in `UserAvatar` with the cached provider; invalidate old/new profile avatars after a successful upload or deletion.
- [x] Run focused cache/component/profile tests and `flutter analyze`.

### Task 4: Full verification and evidence

- [x] Run focused backend and Flutter test commands, then `pwsh -NoProfile -File scripts/verify.ps1`.
- [x] Append exact commands, literal outputs/results, and exit statuses to the verification record.
- [x] Reopen every modified source, plan, and verification document; build and install the debug APK on `emulator-5554` if Flutter verification is green.
