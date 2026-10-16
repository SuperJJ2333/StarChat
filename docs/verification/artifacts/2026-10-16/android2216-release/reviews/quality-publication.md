# Android 2216 publication — independent QUALITY/SECURITY

Verdict: **PASS** for the exact frozen publication package and the separately identified local backfill below. No new actionable quality/security defect found. This is pre-execution approval of the reviewed scope; it does not claim production publication, popup display, or audit completion.

SPEC/domain review was read first: spec-publication.md SHA-256 `54ff38d5c1daaf2a91ab6e13d215301d8025bedee1cfaf3bd54c480e61394017`. Reviewed the 2215→2216 adaptation, frozen executor and runtime, 35-test evidence, PostgreSQL source closure and local backfill. Used the starchat-admin-production skill and current production runbook. No remote commands, mutations, builds, full suites, signing, source/index changes or new PostgreSQL execution were performed. Read-only hashing is verification, not a duplicate build gate.

## Exact approval identity

| Item | SHA-256 |
| --- | --- |
| Package freeze-manifest.json | `5df015a69df956450a6e1d8ec9c728324fce9c3bfa1be2863f18385aa3d551a6` |
| runtime-2216.tar.gz (50,955 bytes) | `7d7812617eb31db6b949a7f7ab3fb1e16f72508ef8896d72b9a503f8da055479` |
| Final APK (73,262,170 bytes) | `db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039` |
| prepared-2216/release.json | `1201983bd54afca2b39b4bc6fa202c3acd424eb6fa123a54d90e7ad3f44c31ea` |
| source_backfill.py, outside runtime | `970f34119313a3bd05f0271c6f9ff4070497c168ea5bdf19b3f52aafc1034394` |
| local-backfill/plan.json | `c9223a1759e515279ff87c4918cbaf676056490a894dcd32c83e1a10813df0ba` |

Independently checked all 38 frozen file hashes and 24 tar member hashes. The package artifact and evidence bind source `35f59abbb6bdaa0fe6c826aaff904130bb6dea76` / manifest `b07dfdc5a4632f338f27562ea32dd45e280c01fe4da7e4313be1bdb2d98a301f`, already accepted in quality-build.md. Imported publication framework is integration e6487ad3 / backend 9d2b3127. Intended operation is `experience-20261016-2216`; executor requires its exact operation identity plus both review-report hashes.

## Security and transaction boundaries

- Executor validates package/archive/runtime bytes before use and rechecks frozen remote runtime files before each payload. Private stages and streamed receivers are exclusive, size/SHA bounded and reject links. SSH host-key and HTTPS verification remain enabled; credentials are not included in the package or printed in error output.
- Fresh preflight compares exact HK settings/schema/dependency hashes, registry/aliases/artifacts, seven static files, permanent guards and 35 service identities, plus SG policy/configuration/role/status. The imported adaptation adds the settings-dependency comparison; old captured state cannot silently authorize a changed current state.
- Immutable versioned APK installation preserves the prior file and refuses replacement with different bytes. CloudFront adds only the approved new path using current ETag/If-Match; bucket policy stays byte-preserved. Fresh Deployed plus public HEAD/MIME/length/CORS checks precede alias switch and publication. No full public APK redownload or new signature claim is introduced.
- Online file writes are exactly download.html and downloads/android-release.json. The other five checked static files, including iOS manifest and admin-home.js, are preserved. Host locks, exact before/after hashes, raw private backups and per-file CAS protect these writes. Only verified original bytes are restored before the database phase; commit/readback uncertainty records unknown and stops.
- The database path uses SettingsService, advisory and row locks, one outer PostgreSQL transaction and exact ten-key CAS. Only app_latest_version, app_latest_build and app_update_notes change. Exactly three trace-bound before/after audit events are checked before commit; replayed traces fail. iOS latest remains 0.4.46+2215, both minimum builds remain 3, and URLs remain unchanged. No ledger/auth/E2EE/migration or service restart operation exists in this scope.
- Mutation phases require the matching previous receipt and refuse replay after a prior attempt or unknown outcome. Exclusive inflight state also fails closed. Read-only inspection/audit remain available. Cross-host and filesystem/database phases are explicitly separate; no global atomicity claim is made.

The recorded 35 local boundary tests pass. The six earlier PostgreSQL cases are reused because the transaction body is byte-exact and the normalized module/test changes are version/notes/trace constants. The four live dependency hashes match the tested closure. Current API image differs: this is source-closure reuse, not a new live PostgreSQL test or whole-image equivalence. Fresh preflight must still pass at execution time.

## Separate local reconciliation

Independently verified all seven current local before-hashes and four staged target hashes. The two Android outputs match the frozen package. The local iOS manifest reconciles already-live metadata; this adds no remote iOS write. admin-home.js is derived from its exact local bytes with only the two existing iOS version/build label pairs replaced. All other bytes, including expectedCacheEpoch/getCacheEpoch wallet authentication checks, remain intact; copying live admin-home.js wholesale is not approved. Three network scripts remain unchanged.

The local apply path requires actual publish and audit PASS receipts bound to the same freeze, three audits and Android build2216, then rechecks all before/staged hashes. Local writes are not a multi-file transaction; interruption leaves a visible partial state that fails the original before checks and requires inspection instead of a blind replay. This local recovery limitation does not affect server state. Root retains final exact-diff/hash review before commit.

## Execution and acceptance still required

Root may execute only the artifact-bound reviewed operation after its fresh checks pass. Actual immutable upload/CDN readiness/alias/static/settings results, audit and ordinary client-popup acceptance remain pending. Existing libcrypto P1 16KiB limitation, no ARM64 physical-device acceptance and global verify environment limitations remain recorded; this publication review does not waive or relabel them.

Review completed: 2026-10-16T10:58:22.2750383+08:00.

