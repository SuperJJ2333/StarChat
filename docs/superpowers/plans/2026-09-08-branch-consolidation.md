# Branch consolidation execution plan

> **For agentic workers:** Use subagent-driven-development for bounded independent reviews. User approved this sequence in the current task on 2026-09-08; execute without another approval menu.

**Goal:** Preserve uncommitted work, integrate verified fixes and iOS diagnostics, archive evidence, and retire redundant branches and inactive worktrees without losing ongoing work.

**Architecture:** Keep the actively edited root and iOS checkout intact. Snapshot local source and Git history before integration. Perform integration in a separate worktree based on main, with specification review before quality review. Financial/authentication changes require applicable ADR and domain/security approval; preserve them separately when not merge-ready.

**Tech Stack:** Git, PowerShell 7, Python, Flutter, GitHub Actions.

- [ ] Inventory current refs/worktrees and active task ownership; record exact revisions.
- [ ] Save binary Git patches, current uncommitted source/documentation, and a verified Git bundle below docs/verification/artifacts/2026-09-08/branch-consolidation/. Keep raw snapshots local and excluded from Git; record hashes and restore instructions.
- [ ] Create isolated codex/consolidate-20260908 worktree from main. Inspect relevant AGENTS and baseline tests.
- [ ] Reproduce direct-room sync regression using the existing uncommitted regression test on main, then apply only the bounded timeout fix and run focused tests.
- [ ] Integrate a pinned iOS diagnostic revision only after checking its actual validation status. Extend workflow triggers for main/PR/manual invocation where appropriate, preserving read-only permissions and synthetic data boundaries. Do not treat simulator diagnostics as true-device call/push validation.
- [ ] Review specification compliance, then code quality/security. Run focused Flutter tests, analyzer and scripts/verify.ps1. Resolve integration failures; do not publish failing code as verified.
- [ ] Fast-forward local main after successful checks; update remote main only with ordinary fast-forward push and recheck remote head.
- [ ] Archive useful evidence and uncommitted files before removing inactive worktrees. Check resolved absolute paths, archive integrity, and unchanged source fingerprints immediately before removal. Preserve any active worktree or newly divergent ref.
- [ ] Remove only branches proven ancestors of final main; use expected-value checks for remote deletions. Retain active iOS branch and current root branch while other tasks use them.
- [ ] Record final refs, worktrees, preserved pending work, archive hashes, test outcomes, and restore instructions in docs/verification/2026-09-08-branch-consolidation.md.

Ownership: this task owns the plan, branch-consolidation evidence folder, and files in its new integration worktree only. Root product files and the active iOS worktree belong to existing user tasks.
