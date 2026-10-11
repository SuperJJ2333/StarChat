# iOS native storage: capability-aware XCTest candidate and independent privacy review

Task owner: `/root/fix_scheduler_r6`. Isolated branch: `codex/im-ios-storage-gate`.
Input: `9dcd48441bff06d8c69e20255dd9189719bf50c2`. Local verification finished at 2026-10-11 05:58:27 UTC.
Authorization: root's bounded iOS gate assignment and explicit approval of the capability probe / strict-production design. No deployment, signing, enterprise workflow or version changes.

## Gate implementation (self-authored, requires root review)

The historical native RED is retained: actual iOS 26 Simulator run `38115523536` reported 5 tests, 4 failed, with `protectionUnavailable`. Its synthetic probe reported `protection=nil`, backup exclusion `true`, and nonnegative important capacity after setting Data Protection. This is an environment capability gap; production correctly refuses to report protected storage.

- Source evidence zip SHA256: `dda772a2af0c25c23714521a8fe22400a6a0769ac1cd17d8c8442356c09cf95c`.
- Extracted capability text `2B99EEB7-FBC6-4D94-8336-9173893A2D2F.txt` SHA256: `86996b937aec9ed72602f3a9a899e0596c7c634dc528970d0fab118a15de3e8f`.
- Both are under root's `docs/verification/artifacts/2026-10-11/im-reliability-implementation/native-capabilities-38115523536/`. The zip identity is not the text-file identity. No runtime database or user data was copied.

Four existing protection-success XCTest cases now call a synthetic AppSupport capability probe first. The probe explicitly sets `completeUntilFirstUserAuthentication`, reads it back, verifies backup exclusion and checks important capacity. Only a Simulator build, with nil protection and both other capabilities valid, can throw `XCTSkip`. An actual device has no skip branch. Wrong non-nil protection, unexpected I/O failure, exclusion failure or missing/negative capacity cannot qualify for this skip.

Two new non-skipped XCTest cases cover (1) repeated real production calls matching the observed capability, including exact `protectionUnavailable` on unsupported Simulator and preservation of an existing marker, and (2) entry validation for regular files/directories, wrong types, missing files, traversal, prefix siblings, ordinary/ancestor symlinks and dangling WAL/part entries, plus invalid production identifiers. They do not manufacture a successful protected result.

Production change is solely extraction of the existing entry guard into internal `validateEntry`; `apply` calls it unconditionally before setting protection/exclusion and strict readback. No production conditional compilation, injected successful protection value, channel argument expansion or fallback storage was added. `verify_local.py` inverts exactly this extraction and confirms the complete Swift file equals the baseline afterward.

The CI workflow preserves the raw `xcresulttool get test-results summary` JSON and renders it unmodified in the job summary. SKIP is explicitly not PASS. No inferred success count replaces the raw result. The native input manifest now also hashes the privacy manifest. The existing diagnostic host and production-package limitation remain explicit.

### Verification and limits

- Local `verify_local.py`: exit 0. YAML and all three embedded Python blocks parse. Synthetic summary formatting preserves 4 PASS + 4 SKIP + 0 FAIL exactly; these numbers are formatter fixture data, **not a real XCTest result**.
- Existing privacy plist/PBX test: 1 passed, exit 0 (`privacy-test.txt`).
- `git diff --check`: exit 0.
- Swift compilation and new XCTest execution: **NOT RUN on this Windows host**. No new runtime GREEN is claimed. The prior actual RED remains the evidence for the environment mismatch, not evidence that this candidate has passed.
- `scripts/verify.ps1`: not launched after preflight found no `.env`; unrelated render/service gates belong to root's final candidate. This does not waive the native compilation/test gate.
- Candidate contains 8 XCTest methods. A Simulator with the already observed capabilities is expected to report 4 PASS / 4 SKIP / 0 FAIL only if the other assertions work; macOS CI must establish the actual result. A capable real device must execute all 8 without skip.

Next executable step: root SPEC then QUALITY review of this self-authored diff, followed by remote macOS/Xcode 26.3 CI. Keep device Data Protection, full-plugin build, backup exclusion, lock/unlock and release acceptance pending. No production release approval is issued by this report.

## Privacy manifest independent review

Exact reviewed commit: `d17689f2c5010e9659846a503173ac7b0b4a08fb`. The manifest and PBX file are byte-identical Git blobs at the review baseline. This section reviews another author's change; it does not independently approve the gate implementation above.

SPEC review: the manifest declares the three requested API categories. `FileTimestamp/C617.1` matches `lstat` metadata checks on fixed app-container files; `UserDefaults/CA92.1` matches app-owned keys in `UserDefaults.standard` (`IOSCallsBridge` call activation and `IOSBackgroundMediaDownload` local identity). `DiskSpace/E174.1` is the correct category/reason for the intended local write-admission checks, provided the final integrated client observes the capacity and visibly refuses insufficient-space operations. Apple requires that behavior and prohibits sending disk-space information off device for this reason. [Apple required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

QUALITY review: plist parsing succeeds; each category has a string reason array. The file reference `CF1011000000000000000003` belongs to Runner, and build-file `CF1011100000000000000003` is in Runner's `97C146EC1CF9000F007C117D` Resources phase, not merely RunnerTests. The added XCTest checks `Bundle.main`, so macOS execution must still establish real target packaging. No collection/tracking declaration, permission change, secret or alternate path is introduced by this commit.

Conditional finding: at frozen `9dcd4844`, production Dart consumption of native `availableBytes` is not yet integrated. Root reports a separate imminent durable-store commit with admission reserve checks and visible low-space errors; this needs exact-commit verification before closing E174.1. Therefore the category mapping and PBX source wiring pass independent inspection, while integrated E174.1 behavior and built-bundle evidence remain pending. This review is not a complete app/third-party SDK privacy audit or App Store approval.
