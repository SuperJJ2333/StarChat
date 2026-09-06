# Track the patched Matrix SDK implementation plan

Approved scope: user explicitly requested retaining the customized SDK in Git or a pinned accessible Git dependency, changing the dependency setup and pushing.

Goal: a clean checkout resolves the existing Matrix 0.34.0 path dependency without relying on files ignored on a developer machine.

Architecture: retain the current local dependency and its existing call-session patch unchanged. Track only its lib tree, package metadata, license and provenance. Keep other third-party directories and build outputs ignored.

Owned files: .gitignore; .gitattributes (preserve vendor snapshot bytes); apps/mobile_flutter/pubspec.yaml; apps/mobile_flutter/third_party/matrix/**; tests/mobile/test_vendored_matrix_dependency.py; this plan; docs/verification/2026-09-06-matrix-sdk-ci.md. Other ongoing chat changes are outside this commit.

1. Add and run a repository regression checking the path package and complete provenance file list in a clean worktree. Confirm failure before copying SDK.
2. Copy the exact local SDK snapshot and verify hashes match the original. Narrow the ignore exception to required package files; retain LICENSE and CHATFLOW_PATCH.md.
3. Verify tracked-file archive contains SDK, resolve dependencies in the isolated checkout, run Flutter analyze/test and scripts/verify.ps1. Record failures and distinguish environment/baseline issues.
4. Review specification compliance, then repository hygiene/security and diff scope. Commit only owned changes; push normally, never force push.
5. Inspect the resulting android-ci run. Address failures caused by this change and report the actual outcome.
