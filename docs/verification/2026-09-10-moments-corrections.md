# Redmi feedback corrections

Base: `aa40f154`, isolated `codex/redmi-polish-20260909` worktree. User feedback on Debug 2076 defines this correction.

## Cause and fix

1. Fixed #333 comment styling ignored the active theme. Reactions now resolve navigation background, text, secondary text, links, selection and dividers for light/dark mode. Light→dark→light tests confirm repaint; blank reaction taps do not open post detail.
2. Feed/personal `onCommentTap` still called the detail route. A shared `interactWithMomentComment` handles all three pages in place: other-person reply and selection, own Copy/Delete, latest-item merge and privacy revision checks. Avatar/name and image targets remain independent.
3. A 96px avatar was placed directly in a vertical ListView and stretched to full width. User/friend profiles now share `ProfileIdentityCard`: bounded 72×72 avatar and responsive name/account column. Eligible nonfriend only has Add to Contacts; self/friend/pending cannot submit an invalid request. Adding still opens the existing request page.

## Verification

- Theme tests initially failed on fixed-dark background; corrected suite 5 passed. Dynamic color assertions compare rendered ARGB values rather than dynamic-wrapper identity.
- Four actual feed/personal tap cases initially failed because `MomentDetailPage` appeared; now pass with same-page composer/selection or Copy/Delete. All Moments feature tests: 75 passed.
- Profile tests reproduced 320×96 stretched avatar and large-text friend header overflow; fixed layout tests cover 320px and 2× text. Related 30 tests and 8 layout/fixture tests passed.
- Full Flutter suite: **1643 passed**. Full analyzer: **no issues**. HTML Node: **28 passed**. Headless browser screen/theme/profile contract: **passed**. Local UI registry: **19 components / 331 screens**.
- Repository full-run backend: **1510 passed, 37 skipped**, 667.67 seconds. The skips and Starlette/httpx/Alembic deprecation warnings are existing baseline, not new passes or UI failures.
- The complete `scripts/verify.ps1` run finished with **Verification: PASS**, exit 0: policies, infra, bridges, backend, all 66 mobile boundary checks, UI contract, API import, AST, Alembic, OpenAPI and Compose. Temporary example `.env` removed afterward. Full log: `artifacts/2026-09-10/moments-corrections/verify.log`.
- Independent specification review: PASS. Independent quality/security review after spec review: PASS. Async comment result guards preserve current likes and reject obsolete privacy revisions.
- Actual Flutter profile fixture and HTML light-theme reaction rendering inspected. Evidence in `artifacts/2026-09-10/moments-corrections/user-profile-fixture.png` and `comments-light.png`.

## Debug delivery

- Redmi Note 7 `cbd0156b`, full standard ARM64 package `com.liuhetong.mobile`.
- **0.3.73-debug / 2077** installed with `adb install --no-streaming -r`: **Success**. PackageManager confirms version; launch **Status: ok**; process 11889 at verification. No uninstall/data clear/normal-package Flutter drive.
- Apktool 2.12.1 decode/rebuild/redecode and build-tools 36.0.0 alignment/signature verified. Existing Redmi Debug signer retained: `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`.
- 26537 classes and 338 native/Flutter assets match source; manifest semantics identical. ARM64/Debug-kernel ZIP gate passed. New kernel contains `interactWithMomentComment` and `ProfileIdentityCard` (absent from 2076), ruling out a stale source build.
- Final and installed APK SHA256: `c0e20c941e6130ab06d22302a97cef70db6e6363230aadd8d0073811bc3fcd56`; size 142371666 bytes. Final APK and build/install evidence: `artifacts/2026-09-10/moments-corrections/redmi-2077/`.
- Phone Download copy `/sdcard/Download/ChangLiao-0.3.73-debug-2077.apk` matches the same SHA256.
- Three HTTPS build definitions for Business API, Matrix and Getui retained. Build emitted existing plugin KGP migration warning but succeeded.

## Scope and design record

Real-device installation/startup verified; interaction/large-text/theme regressions use isolated widget/browser fixtures. No live comments/messages sent. Existing client stranger filtering is preserved; earlier server privacy/GIF enhancements remain undeployed. No release-channel or iOS update.

Flutter/HTML, `frontend/artifacts/figma-state.json`, and `packages/ui-contracts/changliao-component-registry.json` updated. Existing Figma targets: [Moments 19:4](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78?node-id=19-4), [Contacts 19:3](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78?node-id=19-3). No callable Figma editor; remote synchronization remains pending and is not claimed complete.
