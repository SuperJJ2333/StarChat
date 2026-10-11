# iOS cold SQLCipher order gate extension

Owner review_r1_r2, explicitly requested by root after storage factory commit 9218be3720cd39128445691697787b371304bf58 was integrated as a37fad28. This follow-up owns only integration_test/sqlcipher_readonly_native_test.dart and dedicated evidence. No production/native helper/CI workflow changes; no subagent spawned. Base 9218be37, clean source before this addition.

## Added gate and static self-review

The existing ios-enterprise-package workflow already names sqlcipher_readonly_native_test.dart (line 273 in the inspected workflow), so its two added testWidgets cases run through the existing CI entry. Existing four read-only/legacy SQLCipher cases remain unchanged.

Each new case asserts Platform.isIOS and calls Isolate.run independently. The closure captures only the immutable order flag. A fresh caller isolate means a fresh sqflite_common_ffi library singleton and worker; one case cannot warm the other. Creating the keyed factory does not perform SQL. The first actual open is localMetadataDatabaseFactory.openDatabase or the Matrix-style keyed factory, depending on the case. No library warm-up, injected backend, platform channel or PendingMediaDirectory is used.

Both connections must return nonempty PRAGMA cipher_version. Independent synthetic tables are written using the unkeyed production metadata factory and a separately keyed connection. Both are really closed, then their file headers are checked: metadata remains SQLite format 3, the keyed file does not. Both handles reopen; a third singleInstance:false handle with a deliberately wrong synthetic key must fail with DatabaseException. Subsequent reads on the correct metadata and keyed handles must still return their own markers. The sequence checks actual persisted bytes and connection-local key isolation rather than asserting only successful construction.

All content, paths and keys are synthetic. Each invocation owns a unique Directory.systemTemp subtree, closes handles in finally and deletes that subtree. No user database, recovery key, production token or existing pending original is read/changed. The gate intentionally does not query or weaken file protection. Passing it must not be reported as protected pending-media acceptance; the separate native media persistence/protection fixture is unchanged.

## Verification and limits

`dart format integration_test/sqlcipher_readonly_native_test.dart`: 1 file formatted.

`dart analyze integration_test/sqlcipher_readonly_native_test.dart`: exit 0, No issues found; ios-cold-factory-analyze.txt. PowerShell 7 UTF8NoBOM console/pipeline/Python UTF8 environment; Flutter 3.44.9/Dart 3.12.2. `git diff --check` passes.

Static self-review performed SPEC/domain then quality: exact two fresh-isolate orders, no pre-warm/channel/protection dependency, distinct connections, actual close/reopen, wrong-key failure then correct reads, unchanged original four cases, no production diff. This is implementer self-review, not an independent PASS. Root will independently review the frozen commit.

The parent storage fix already has test-first Windows real-SQLCipher metadata-first RED / reverse-order PASS, then both GREEN, followed by 135 affected PASS and 9-file analyze 0. Those exact prior artifacts remain database-factory-*. They are a production-fix baseline, not execution of this new iOS-only fixture. New iOS cases have not run on Windows or a device; no native PASS is claimed. Do not rerun the monorepo gate solely for this test-only addition: parent owns shared/CI execution and the existing iOS workflow will execute this file.

## Evidence and next executable step

Inputs/log hash and observable timestamps in ios-cold-factory-input-hashes.json. Active investigation minutes are not independently measured. Next: root cherry-pick this one follow-up commit, review it, and run the existing iOS CI gate. Native library/linkage failures must remain failures; no policy mocking or simulator protection relaxation is authorized by this change. Reverting this commit removes only the extra gate, with no production/storage effect.
