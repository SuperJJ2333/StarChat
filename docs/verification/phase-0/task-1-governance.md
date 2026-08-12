# Phase 0 Task 1 Verification — Repository Governance

**Verified:** 2026-08-12 (Asia/Hong_Kong)

## Red evidence

Command:

```powershell
pwsh -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1
```

Exit code: `1`

Expected failure:

```text
.superpowers/ must be ignored
```

## Green evidence

The same command exited `0` with:

```text
Repository policy: PASS
```

## Files

- Created `tests/repository/Test-RepositoryPolicy.ps1`
- Created `AGENTS.md`
- Created `infra/AGENTS.md`
- Created `services/matrix-bot/AGENTS.md`
- Updated `.gitignore`

No Git commit was created because the supplied workspace is not a Git repository.
