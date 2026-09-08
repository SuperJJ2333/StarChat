# Committed branch integration into main

## Scope

User authorization: merge the latest committed changes from other branches into main. The user explicitly excluded uncommitted wallet, backend, iOS, and other workspace changes. Work was performed in the isolated `codex/integrate-main-20260908` worktree. No APK distribution, server deployment, or update-dialog publication is part of this task.

Local main started at `4afbc6c7`; origin/main started at `803debf8`. The local main-only wallet design commit is retained.

## Integrated branch tips

| Branch | Recorded tip | Integration decision |
| --- | --- | --- |
| codex/image-layout-mi6 | 097a6ba4 | Latest chat/media/image layout and release baseline |
| codex/wallet-safety-mi6 | 1bc3fe59 | Preserve committed wallet and image evidence |
| codex/chat-room-flow-fixes | 9f3cef8e | Preserve ancestry; overlapping older code must not replace newer fixes |
| codex/ios-0353-background | 21f99300 | Native call/background/Keychain and gateway code |
| origin/codex/ios-0353-testflight | a797f28f | iOS workflows; includes preflight 800a5290 |
| origin/codex/ios-startup-repair-20260907 | aa67b302 | SQLCipher linking and startup diagnostics |
| origin/codex/ios-secrets-check-20260907-151818 | 0cd579a6 | Existing iOS secret configuration check workflow |
| feat/e2ee-session-continuity | 035c47ac | Managed capabilities, non-destructive session continuity, decryption recovery |

The cache-entry, feedback, release-settings, review3, tracked-SDK, official-chat-update, and official-wallet-address tips were already ancestors of these candidates. Final ancestry verification covers every local and origin branch reference, including duplicate tips.

## Semantic conflict resolution and review

The August E2EE branch still embedded RoomPage inside MatrixHomePage. The September branch had extracted and substantially updated RoomPage. The integration keeps the newer standalone page and adapts it to lifecycle-managed room leases, without exposing SDK clients through UI accessors.

Preserved behavior includes cached startup, blank undecrypted conversation summaries, contact remarks, group names and permissions, image contain/alignment, original GIF bytes, media/session caching, drafts, mentions/search, transaction-aware outgoing ordering, profile message navigation, native calls, push notifications, and Moments unread indicators.

Specification/domain review preceded quality/security review. Review found and corrected:

- Cached-only startup skipping the local conversation snapshot; a failing widget regression was made green.
- Global search including undecrypted event placeholders.
- Missing profile message callbacks in two RoomPage entry paths.
- Unconditional SDK sync auto-join bypassing the newer business preference.
- Delayed room media shutdown initializing an unused native audio player.
- Managed home construction re-entering the lifecycle queue or rejecting a client during authorized reattachment.
- Revoked push cleanup losing authority to unregister its own previously created registration.
- Decrypted event cache surviving an explicit account clear. Cache keys now include account, room, and event; clear and continuity changes remove sensitive state, and late SDK events cannot refill it.
- Backup-key creation completing after clear and restoring a recovery key; publication is guarded and secrets are cleared again after draining.
- Notification initialization completing after disposal and reinstalling old global handles.
- Push/iOS/native initialization outliving a resource generation. Startup flights are invalidated and drained before cleanup and reattachment; callbacks retain their original generation.
- Incoming call routes and native notifications surviving managed detach. Detach removes its owned route and serializes notification cleanup against new presentation.
- Startup key recovery resuming synchronization after logout. Recovery runs only in the same authenticated bootstrap generation; background sync cannot grant lifecycle access.

The account-clear/cache, lifecycle reattachment, startup-drain, and notification cleanup fixes received independent implementation review and dedicated regression tests. Domain and quality/security reviews found no remaining blockers in those fixes. This is an integration review under ADR 0007, not a claim of production Synapse or real-device E2EE certification.

## Verification

Repository `scripts/verify.ps1`: PASS. Infra 17, Getui bridge 28, Matrix bot 9, business API/worker 349, mobile boundary 66 tests passed. Business tests skipped 19 environment-dependent cases. UI contract (17 components/330 screens), OpenAPI, AST, Alembic single-head/offline SQL, and Docker Compose rendering passed. Existing Python dependency deprecation warnings are unrelated to this merge.

iOS call gateway: 53 tests passed. Native iOS archive validation requires macOS and is not represented as run on this Windows host.

Final frozen-source validation:

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub --reporter expanded`: **1448 passed**, zero failures.
- `flutter build apk --debug --flavor standard --target-platform android-arm64 --no-pub`: PASS. Existing third-party Kotlin migration/deprecated native API warnings remain; compilation succeeds.
- Mobile Python boundary tests re-run after lifecycle corrections: **66 passed**.
- Final fetch and coverage check: **24 local/origin refs**, none outside the candidate and E2EE merge parents. The final merge ancestry is checked again before updating main.
- The lib/test diff fingerprint remained `5a33e0ee48c69a770abe4a8caac7457d75ddbd10` throughout the final checks.

Raw debug build output is only a compilation intermediate and is not delivered or signed as a user release in this task. Detailed command logs remain local under `docs/verification/merge-*.log`; generated APKs and logs are not staged.
