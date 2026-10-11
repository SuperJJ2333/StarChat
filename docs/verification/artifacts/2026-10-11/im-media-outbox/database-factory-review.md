# Database factory initialization: independent review

Scope: the nine-file working-tree delta against `36de36707869a8c73e0a298130e27fe453e95662` in `im-media-outbox/StarChat`: seven production files, one Windows unit fixture and one native integration fixture. Reviewer: `media_identity_review`, 2026-10-11. Source/test inspection was read-only; this report is the only reviewer-written file. No tests were rerun by the reviewer.

## Specification and domain review — PASS

The native API 28 failure is consistent with the actual dependency implementation, independently inspected in the resolved `pub.dev/sqflite_common_ffi-2.3.6` source. `database_factory_ffi_io.dart` owns one `_isolate` per calling Dart isolate; `_isolateHandle` passes `ffiInit` only when creating that worker. `isolate.dart` invokes the callback once inside the worker before processing SQL calls. Creating another factory later does not replace that worker or run its initializer. The earlier native `native-storage2214-r2/native-drive.log` fails in `SqliteMediaOutboxStore._open` while loading missing `libsqlite3.so`.

The new `localMetadataDatabaseFactory` uses the same existing `SQfLiteEncryptionHelper.ffiInit` as Matrix. All six metadata default constructors now select it: media outbox, text outbox, moments pages, media disk quota, media index and profiles. Explicitly injected factories remain supported. The helper only selects the already packaged SQLCipher dynamic library. This delta adds no PRAGMA, database key, schema/migration, table query, path, or file-format change. In particular, the metadata constructors never call `applyPragmaKey` or `ensureDatabaseFileEncrypted`. Existing Matrix key configuration stays on its own connections. The MediaIndex comment now matches this order-independent default rather than claiming Matrix must initialize first.

Checked other production entry points: MatrixClientFactory deletion, archive reading and persistent opening already pass this same initializer; local identity preflight does too. The four direct sqlite3 migration-worker entry points call the helper before their first sqlite3 access in their own isolates. Native SDK `BoxCollection.open` requires an already open Database rather than silently opening a default. Its optional default factory is only in deletion helpers; the production `CooperativeMatrixDatabase` is passed the explicit Matrix factory. No further production bare-default opener was found in `apps/mobile_flutter/lib`.

Both new fixtures run each order in a fresh `Isolate.run`, giving each order its own caller-library `_isolate` and a newly initialized sqflite worker. Merely constructing the cipher factory before the metadata call performs no SQL and does not invalidate the metadata-first order. The unit fixture exercises the real default media-outbox factory and a real SQLCipher connection, while explicitly doubling only the native directory/capacity/sealing policy. The native fixture registers `BackgroundIsolateBinaryMessenger` with the real root token and uses the real method channel, default store, directory/capacity provider and sealing implementation, with no factory or policy injection. The two native orders are therefore suitable pending device executions, not a claim that device acceptance has occurred.

Each order creates metadata and encrypted handles, persists a synthetic original, really closes/replaces the store, restores the queued row/source, closes/reopens the encrypted handle with the correct key, rejects a separately opened wrong-key connection, and proves that the correct connection still reads its marker. Metadata retains the plain SQLite header; the encrypted probe does not. The native fixture additionally cancels and deletes the source while the keyed connection is open. This checks connection-local keys without expanding the production key boundary.

## Quality and security review — PASS

Reviewed after the specification/domain pass. No blocking finding in this bounded delta. All production changes are imports/default-factory selection and comments; no fallback to plaintext Matrix storage, credential handling, encryption bypass, global key PRAGMA or migration is introduced. The helper uses the existing packaged-library loader rather than downloading or selecting a new native dependency.

The fixtures use nonsecret synthetic keys/accounts/bytes and isolated owned directories. Wrong-key opens use `singleInstance: false`, avoiding accidental reuse of a correctly keyed handle; a successful correct-key read follows rejection. Handles are closed in finally paths and synthetic files are cleaned up. Native scope construction checks containment within the actual fixed pending root. The additional synthetic cipher file does not bypass or replace the existing manifest/source sealing calls. Errors still propagate; there are no ignored/skipped tests or timed completion substitutes in this change.

Inspected implementer evidence (not reviewer reruns):

- `database-factory-red.txt`: initial two-case database-open/path failure; preserved as fixture setup evidence, not the meaningful product RED.
- `database-factory-behavior-red.txt`: metadata-first fails with SQLCipher unavailable, while cipher-first passes, demonstrating the first-factory dependency on a fresh worker.
- `database-factory-green.txt`: both cold orders pass after default-factory correction.
- `database-factory-analyze.txt`: initial two unnecessary-import notices, retained and corrected.
- `database-factory-analyze-final.txt`: all nine changed Dart files report no issues.
- `database-factory-final.txt`: final 11-file run reports 135 passed, including the existing 700 synthetic persistence-boundary iterations. Implementer reports exit 0 and no failures/skips.
- Reviewer `git diff --check` on the changed paths found no whitespace errors. Git emitted only its existing CRLF-to-LF normalization notice for the media store.

Limits: these are Windows SQLCipher and Dart verification results. The earlier API 28 run remains a failing pre-fix native run. The changed two-order Android/iOS fixture has not yet been executed on a new native candidate. This report does not claim native, full-suite, package or device acceptance; root owns those remaining gates.

## Exact reviewed identities

SHA-256 below identifies the working-tree bytes, including untracked new source/test files. Log identities are recorded after the final run completed.

| Input | SHA-256 |
| --- | --- |
| `apps/mobile_flutter/lib/core/local_database_factory.dart` | `e04ab30397ff76dccef64c1afe9111ac95d4a24328b4038ca24c66ede780634b` |
| `apps/mobile_flutter/lib/core/outbox/media_outbox_store.dart` | `0553adf3fd28d443d72b93ce9bf1352666bc08159cd16ac07e430b4d42701efa` |
| `apps/mobile_flutter/lib/core/outbox/outbox_store.dart` | `5c032cbbc7715774057ee9a414b9f94d51b25ec75b93e2877c2a2d66e57fd251` |
| `apps/mobile_flutter/lib/core/cache/moments_page_store.dart` | `9a09e554cd95956d344f07fae742d7ef4ccf3c613bd9306afac859ca4619e70a` |
| `apps/mobile_flutter/lib/features/matrix/media_disk_quota_index.dart` | `a4ebfc422aabb03bd36a0637217e94818f8f48ca1e68d50c2b19b37f7aa45844` |
| `apps/mobile_flutter/lib/features/matrix/media_index.dart` | `04536bbf3e60843011869b991290e0a49ec6d5b86a349f88b3894280c726fc30` |
| `apps/mobile_flutter/lib/features/matrix/profile_repository.dart` | `c9f53f71ec7749d0cde724554e0e293ab61a0341a622aad751069ff2ad7b726d` |
| `apps/mobile_flutter/test/core/local_database_factory_test.dart` | `e81f49af9051c3916613dae91c23dc4af66ced239c2890a0c07e46a8f9de5d32` |
| `apps/mobile_flutter/integration_test/media_outbox_persistence_native_test.dart` | `cf9baeded624985c880c6c9fe7ad32a11798fbcd47b83dbb61be7f8a628b8d60` |
| `database-factory-red.txt` | `4c4a0405ac88e7616991881b503e70f1bd33d27c09cf87248e8e373d47e61808` |
| `database-factory-behavior-red.txt` | `d644bcd8c8cff42a7b1a7def72cb83bd80c967bca89d341c2f04958cada059f7` |
| `database-factory-green.txt` | `d651073c6086ce380107b43911ddc68de2799e6c16c9be7ace9a5e4b7764c9e9` |
| `database-factory-analyze.txt` | `eec2912583ab1ca885bbeebf502b3612a98b817f2a10e2c0eda1ee3b0d932e5c` |
| `database-factory-analyze-final.txt` | `42eb8399f584689052209058eb28b004bbbebfc935d68b75ddfa017d3ec90944` |
| `database-factory-final.txt` | `5a536b596dcb08fd3fbf494951a043bc2834b8a58d1157c33410250d92ccfa23` |
