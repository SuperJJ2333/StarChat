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
