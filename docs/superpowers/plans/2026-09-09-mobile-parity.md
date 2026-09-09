# Mobile parity and compatibility release

User approved completing the diagnosed Moments gaps and history validation, then building both platforms from the same source on 2026-09-09. Extends the existing approved cache, interaction, image-layout and iOS diagnostic designs. Branch: codex/mobile-parity-20260909, based on main be14e743.

## Design and ownership

- Root owns Moments page/model/feed cache and tests: synchronously reuse account-scoped in-memory feed on reentry, retain disk fallback and background refresh, cache cover preferences, update liked/count/like-user list immediately with rollback and persist successful interaction state. Do not display another account's cache. Keep server authority and avoid stale refresh undoing confirmed mutations.
- Media subagent owns Moments image grid/viewer and a shared media cache component/tests only: use the existing pinned cached_network_image/cache_manager dependencies for bounded disk reuse without fades on cache hits. Preserve existing layout and gestures. No new backend endpoints or third-party uploads.
- History subagent owns additional authentication/storage regression tests and evidence only: audit current main against approved ADR-0007; exercise logout, restart, missing/invalid business credentials, Matrix token errors, same-account reauthentication and account isolation. No protected production changes without reporting evidence first.
- Root integrates, performs specification then quality/security review using subagent-driven-development, runs targeted and full Flutter/analyzer/repository verification, and extends cloud native tests where useful.
- Build Android ARM64 through docs/runbooks/android-apk-rebuild.md with the fixed signing identity; build iOS through the existing authorized cloud workflow. Use the same committed source and aligned version name, platform-appropriate monotonic build numbers. Verify artifacts and record hashes. Website publication and enterprise re-signing are not implied by merely producing artifacts.

## Acceptance and limits

Tests prove immediate likes including names, unlike/rollback, cached reentry with a pending network request, refresh ordering and account isolation. Media tests prove repeat reads use disk cache. Retain image edge-alignment regressions. Native audio/video and encrypted storage restart diagnostics run on iPhone 15 iOS 18/26; simulator results do not substitute for enterprise re-sign or unavailable physical-phone acceptance.

Figma UI delivery skill applies to visible states. No callable Figma tools were found in this session. Record that gap accurately; do not falsify Figma ledger or claim a design update. Continue independent implementation/verification and revisit design delivery before finalization.

## Review refinements

The state implementation is delegated under the same scope, including a read-only ProfileRepository namespace getter. Specification review rejected trusting that projection alone for cached first paint. Official navigation must prepare the page with the current API session account before pushing it; a directly constructed or mismatched page must not render unverified cached data. This retains the previous screen during local preparation and avoids an empty destination frame without changing authentication. Minimal navigation changes in app_home.dart and discovery_page.dart are included. Repeat the regression/full checks after this correction.

Additional attachment verification uses the shipped Matrix SDK cipher and hash validation with synthetic H264/HEVC fixtures, copying ciphertext to simulate transport and passing decrypted bytes to the production video cache resolver. No live server or real user's attachment is involved. Target build is 0.3.58 (61), preserving the existing formal version-number interpretation.

## Stable media identity follow-up (approved 2026-09-09)

Candidate ff6c5a77 cached original fetch URLs, but Moments signs a new Fernet token into the URL path on each read. User approved fixing that remaining cache miss and rebuilding both platforms from the merged source plus this bounded fix. User explicitly declined importing the unmerged redmi-polish feature branch.

Read-only production inspection found the compatible response fields already deployed from 596601638c3aa0de228942b3b9001cddb0476dfc: image_cache_keys is an index-aligned list of SHA256(original stored image URL), and cover_cache_key is SHA256(cover_object_key or original cover_url). Synchronize only these existing read fields and helper into this source; do not import image comments or other unmerged functionality. Request bodies stay unchanged. Detailed contract: packages/api-contracts/moments-media-cache.md.

Flutter consumes a stable key only when a verified account namespace exists, the supplied digest is 64 lowercase hex characters, and the URL has the exact /api/v1/profile/avatar/content/<single-segment> path on the current Business API origin. Cache identity is SHA256(JSON([current URL origin, account namespace, server digest])). Unknown/foreign URLs, missing identities/fields, and malformed keys retain full-URL fallback. Downloads always use the complete signed URL, with no token decryption or arbitrary query/path stripping. Pass these values through feed, grid, both image viewers, cover header/viewer and cover replacement; persist response fields with existing account snapshots. URL changes remount the image renderer so a renewed URL can recover a prior expired-link failure while a valid memory entry still paints synchronously.

Complete uploads are immutable: acquire the same database row lock in put_content and complete; complete retries return COMPLETED unchanged even after the upload window; overwrites return 409. New content requires a new upload ID/object key and hence a new cache identity. The worker changes Moment moderation state only and does not write MomentMediaUpload or object bytes. No schema migration, new endpoint, auth, E2EE or financial change.

Deployment dependency: the running service already provides read fields and has unrelated newer image-comment logic. DO NOT deploy this checkout's service.py over that production file. Root deploys only the narrowly reviewed media.py immutability patch against its verified baseline. On another older backend, stable reuse starts only after these optional read fields are supplied; clients otherwise remain compatible through URL fallback. Repository-wide verification, independent specification/quality reviews, final common commit and both rebuilt platform artifacts remain required.
