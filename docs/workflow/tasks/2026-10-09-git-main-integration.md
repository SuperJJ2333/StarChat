# Git main integration

## Recovery entry

- Authorization: user requested merging other Git branches into main and a clean Git state. Local integration and recoverable cleanup only; no push or production changes.
- Plan: [integration plan](../../superpowers/plans/2026-10-09-git-main-integration.md).
- Owner: primary agent; root main and named branch integration. Reviewer owns only its review evidence file. Other tasks' detached pending sources remain owned by those tasks.
- Initial main/origin main: `be207f0fece77f0a4585790d7c0932368ac63146`; origin fetched successfully.
- State: complete local integration; all 12 branch tips reachable from main, merged local refs removed, five worktrees safely detached, two missing registrations pruned. Existing directories and pending work retained.
- Latest delivered mobile source: Android 0.4.44+2213 checkpoint `9bc09501412ac02324c47e047c136a4f286118ae` integrated. Published runtime behavior and distribution metadata retained; original license byte hashes preserved explicitly.
- Evidence: `docs/verification/artifacts/2026-10-09/git-main-integration/`.
- Next: no remaining local integration work; remote push and production changes were outside this request. See [final report](../../verification/2026-10-09-git-main-integration.md) and local final-git-receipt.json for final HEAD/status.

## Acceptance

| ID | Requirement | Evidence/status |
| --- | --- | --- |
| G1 | Other named local branch tips reachable from main | PASS: all 12 original tips plus released checkpoint |
| G2 | Primary status clean with no conflict markers | PASS: final receipt binds clean main status and no merge in progress |
| G3 | No unique pending work lost | Inventory plus verified local source archive; unrelated trees retained |
| G4 | Published mobile source and distribution metadata retained | PASS: frozen 1941-input comparison, original license bytes, current channels |
| G5 | Tests/reviews match merged inputs | PASS: split equivalent gates and SPEC then QUALITY reviews; serial verify cancellation explicitly recorded |

## Timing

Initial inventory timestamp is retained in `inventory.json`; exact earlier shell start is not reconstructed. Each integration/check command records its own result and elapsed duration. Recovery archives remain local and ignored.

## Final evidence and timing

See the final report for red/green fixture repairs and gate counts. Local `.env` exists; only the nonsecret code-validity setting was overridden to 15 for schema checks. No credentials were copied to evidence. Inventory timestamp 17:37:52+08; backend shards 545–750s, Flutter 410s plus analyze 22.8s, boundaries 99.28s. Recovery ZIP/bundle were verified before mutations. Cleanup detached five worktrees at identical HEAD/status and removed only fully merged local refs. Exact final timestamp and commit are in final-git-receipt.json.
