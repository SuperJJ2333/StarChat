# Phase 0 Task 5 Verification — Unified Verification

**Verified:** 2026-08-12 (Asia/Hong_Kong)

## Red evidence

After extending repository policy coverage, `tests/repository/Test-RepositoryPolicy.ps1` exited `1` because `scripts/verify.ps1` did not exist.

## Green evidence

Command:

```powershell
pwsh -NoProfile -File scripts/verify.ps1
```

Exit code: `0`

Output summary:

```text
Repository policy: PASS
Deployment policy: PASS
TemplateTools: PASS
Configuration rendering complete.
8 passed in 0.77s
AST parse: PASS (10 files)
Docker Compose render: PASS
Verification: PASS
```

## Covered gates

- Repository and scoped Agent rules
- No floating `latest` references in deployment inputs
- Strict template replacement and unresolved-token rejection
- Render-only Synapse/Element smoke test
- Notification Bot room allowlist and HTTP error mapping
- Python AST parsing
- Docker Compose configuration rendering without a running engine

## Remaining external limitation

Docker Hub manifest inspection timed out during Phase 0. Registry availability and actual container startup remain production-entry checks; no code path falls back to `latest`.

## Files

- Created `services/matrix-bot/requirements-dev.txt`
- Created `scripts/verify.ps1`
- Updated `README.md`
- Extended `tests/repository/Test-RepositoryPolicy.ps1`
