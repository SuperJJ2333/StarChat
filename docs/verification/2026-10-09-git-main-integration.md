# Local Git integration, 2026-10-09

User authorized merging other local branches into main and cleaning Git. No remote push, remote branch deletion, production deployment or new package publication was performed.

## Result and preservation

All 12 original local branch tips, plus the released mobile source checkpoint `9bc09501412ac02324c47e047c136a4f286118ae`, are ancestors of main. Integration merges end at `ffb32b1f`; the subsequent hygiene/evidence commit is identified in the local final receipt. Historical iOS/rollback commits remain reachable while Android 0.4.44+2213 and iOS 0.4.36+2205 distribution metadata remain current. The reviewed staff administration and wallet monitoring branches were integrated with current financial authorization and owner-transfer safeguards.

Before integration, 1779 pending source/documentation files were preserved in a verified local ZIP, and all refs/history were preserved in a verified Git bundle. Their receipts and hashes are under `artifacts/2026-10-09/git-main-integration/`. Recovery archives are ignored and must remain local.

Five branch worktrees were detached at the same commits, with identical pending status before/after. All existing worktree directories, unique uncommitted work and ignored build outputs were retained. Twelve fully merged local branch refs were deleted using `git branch -d`; two missing worktree registrations were pruned. Other tasks' dirty detached worktrees remain intentionally available. Primary main cleanliness is distinct from those retained tasks.

Generated verification artifacts were removed from Git tracking, and the artifacts directory is ignored; existing local evidence was retained. Missing historical binary/runtime dumps were not restored. No signing identity or credentials were changed.

## Integration decisions

- Retained current website Orbit layout and platform-separated release metadata over older branch snapshots.
- Retained current SDK/history/cache behavior and retired an obsolete rollback-only SDK test from active execution; its original commit remains in history and its source is archived locally.
- Preserved staff activation/session boundaries, actor-bound idempotency, audited owner-transfer confirmation and precision. No financial schema or formula was changed by conflict resolution.
- Updated download tests to assert the entire current iOS panel remains byte-identical during Android rendering. The old selector caused two IndexErrors; the corrected focused suite passes 29 tests.
- Updated the older wallet report fixture to create an active finance identity with valid activation and admin scope. Seven 403 failures became passing authorized-report tests; an additional test verifies ordinary App scope and revoked activation remain denied without successful-report audit.
- Scoped the PostgreSQL staff concurrency fixture to mapped identity/admin/support, audit/outbox and FK dependencies. Four tests pass against a dedicated loopback PostgreSQL database, which was removed afterward; no production database was used.
- Preserved original published license bytes using `-text whitespace=cr-at-eol`. The initial Git-normalized checkout failed a license SHA assertion. Restored animated license SHA `03aaf19c01575ca63371ac1ff80926f0e655138009f7d108dae593337a9824b0` and NOTICE SHA `10b96c6174f4e665c0393a9f3cfb1d36124e1da5b10b0566993d4cdb24f565a2` match the frozen release input manifest. These two Git blobs deliberately differ from checkpoint 9bc's newline-normalized blobs. Three other apparent byte differences are CRCRLF normalization only, with identical canonical Git blobs; see `source-canonical-final.json`. No mobile runtime logic was changed after release-source integration.

## Validation

Evidence directory: `docs/verification/artifacts/2026-10-09/git-main-integration/`.

| Gate | Final evidence |
| --- | --- |
| Flutter full tests | 5758 passed, 9 conditional skips; final exit 0, about 6m50s |
| Flutter analyze | No issues, exit 0; 22.8s |
| Frontend full tests | 562 passed, about 11s |
| Mobile Python boundaries | 373 passed, 23 conditional skips; 99.28s |
| Business API/worker full file coverage | Four shards: 865/937/884/1236 passed, 130 total skips; only seven outdated report-fixture failures. Entire affected file rerun: 9 passed, 3.86s. Combined final coverage: 3930 passed, 130 skips, no unresolved failures |
| Staff concurrency on real PostgreSQL | 4 passed; dedicated database removed; 7.81s wrapper |
| Admin/wallet focused checks | 45 admin, 130 wallet, 28 security and 79 owner-route tests passed |
| Repository/deployment/template/render policies | Passed in initial verify invocation |
| Infra / Getui / Matrix bot | 905/38/9 passed; infra 20 conditional skips |
| UI contract | 34 components, 535 screens, passed |
| Python import / AST | Passed, 287 parsed files |
| OpenAPI / migrations / Compose | Passed; single Alembic head 0095, offline SQL generation only |
| Specification then quality/security review | Initial, combined candidate, wallet and final addendum reports |

The serial `scripts/verify.ps1` run was intentionally stopped during business tests and replaced by four isolated shards and explicit remaining gates. Its exit is not claimed as a passing full-script run. After fixture-only changes, unchanged successful files were reused under the mobile workflow's evidence-reuse rule; the entire changed test file was rerun. Existing Starlette/httpx and Getui Pydantic deprecation warnings remain dependency notices, unrelated to integration; no assertions were suppressed. Conditional skips retain their original platform/external-service requirements.

Stage timings: inventory receipt 17:37:52+08; checkpoint/integration and review followed; initial serial verification began around 18:03, replaced by shards taking 9m05s–12m29s. Final exact HEAD/status, branch ancestry and cleanup results are recorded in `final-git-receipt.json`. Previously published native Android/build checks are reused only for unchanged mobile runtime inputs; no new mobile artifact was built or distributed in this task.

Recovery: use the ignored pre-integration bundle for original refs and the source ZIP's manifest for pending-file paths/hashes. Retained detached worktrees can be reattached to new branches without resetting their files. Remote origin/main remains at its fetched state until a separately authorized push.
