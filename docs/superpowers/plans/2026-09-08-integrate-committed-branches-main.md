# Integrate committed branch changes into main

Authorization: the user requested merging the latest branch changes into `main` and explicitly limited the scope to committed changes. Uncommitted wallet, backend, iOS, and verification files in other worktrees are excluded.

## Execution

1. Fetch remote references and record local/remote branch tips and worktree status.
2. Integrate in `codex/integrate-main-20260908`, an isolated worktree based on local main `4afbc6c7`. Preserve branch ancestry with merge commits.
3. Merge image/chat, wallet, iOS code/workflows, and the committed E2EE continuity branch. Resolve overlapping code semantically: retain later chat, cache, image, group, notification, and native call behavior while adapting it to ADR 0007 managed capabilities and non-destructive session cleanup.
4. Verify specification preservation before quality/security review. Run focused regression tests, Flutter analysis and full tests, repository verification, and an Android compilation check. Record actual limitations separately from passing checks.
5. Confirm every recorded branch tip is an ancestor of the candidate, refresh remote main, then fast-forward main and push without force. Keep other worktrees and branches intact.

## Acceptance

- Only committed source from other branches is integrated; no secrets, keys, runtime databases, or uncommitted workspace changes are staged.
- Newer image contain/alignment, drafts, fast cached entry, blank undecrypted summaries, direct-chat routing, group management, and native call handling survive the E2EE merge.
- Managed resources cannot keep using a revoked session. Account cleanup drains owners without queue deadlocks or cross-account requests.
- Branch coverage, test evidence, review findings, and the final main revision are recorded under `docs/verification/`.
- This task does not publish an APK, change update settings, or deploy services.
