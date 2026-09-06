# Matrix SDK clean-checkout CI repair

Scope authorized by the user: publish the required customized Matrix SDK sources and push the dependency fix. Implemented in isolated branch codex/track-matrix-sdk, based on 827db32, without staging ongoing chat changes in the original workspace.

## Root cause and change

Run https://github.com/SuperJJ2333/StarChat/actions/runs/34012062292 failed both Flutter jobs while resolving dependencies: pubspec.yaml references third_party/matrix, but .gitignore excluded the directory. Analyze/tests and Android compilation were not reached.

The existing Matrix 0.34.0 path dependency is retained. Its lib tree and package metadata, LICENSE, README, changelog, patch description and upstream hash manifest are now tracked (183 files, approximately 2 MB source). The incoming-call permission patch is unchanged. The ignore exception excludes other third-party scratch packages and Matrix generated directories; .gitattributes preserves this vendored snapshot byte-for-byte on checkout.

No dependency upgrade, protocol/E2EE behavior edit, signing change or chat feature edit is included.

## Verification

- Test-first: tests/mobile/test_vendored_matrix_dependency.py failed 2/2 before the SDK was copied into the clean worktree; passed 2/2 afterward. The test also passed against files exported from the Git index, so an ignored developer copy cannot hide an incomplete checkout.
- Git-index archive contains all 183 files. Every exported file's SHA256 matches the original customized SDK byte-for-byte; no .dart_tool, build, .git or node_modules directory is tracked.
- flutter pub get succeeds in the isolated worktree.
- flutter pub get --enforce-lockfile succeeds in the tracked-file archive, independently of the original workspace package_config.
- flutter analyze --no-pub: no issues.
- flutter test --no-pub --reporter expanded: 1116/1116 pass after checking out the timeline adapter with its original Git LF bytes. The initial Windows CRLF checkout failed one existing source-string assertion; no application/test behavior was changed to make it pass.
- python pytest tests/mobile -q: 60 passed, including the new dependency checks.
- scripts/verify.ps1 was executed and stops at the existing deployment-policy regex on .env.example. The NGINX_IMAGE value is correctly pinned to nginx:1.27.5-alpine, but its CRLF line does not match the script's LF-only end anchor. This unrelated gate is not claimed green and was not weakened.
- Authored configuration/test/plan diff passes whitespace checking. The unchanged upstream SDK includes existing trailing whitespace; it is deliberately preserved with provenance, not reformatted or reported as a clean whole-vendor whitespace check.
- Specification review followed by quality/security review confirmed required sources, licensing/provenance, original patch retention and absence of generated/runtime/private material. The SDK hash manifest differs from original upstream only for the documented call_session.dart patch.

Raw verification files are under docs/verification/artifacts/2026-09-06/matrix-sdk-ci in the isolated worktree. Generated archives/checkouts are not committed. Remote CI outcome is reported after pushing; this document does not claim an unobserved Android build success.
