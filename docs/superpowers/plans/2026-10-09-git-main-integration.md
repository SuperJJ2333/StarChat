# Git main integration

User explicitly selected local integration into main and a clean Git state on 2026-10-09. No production deployment, remote push, remote deletion, or destruction of unique work is included.

1. Inventory refs, ancestry, worktree ownership and pending paths; preserve pending source/documentation files with verified hashes and a local Git bundle.
2. Commit the primary website/release documentation and the verified Android 0.4.44+2213 source from its existing worktree. Remove missing historical generated artifacts from the index; do not restore runtime databases or package dumps.
3. Review divergent admin/wallet/iOS/rollback branches. Merge their unique commits using three-way integration, retaining the latest published mobile source and distribution metadata where older release branches conflict. Preserve unrelated detached pending work without replaying obsolete snapshots.
4. Run affected merged-source tests, policy checks and appropriate verification. Independently review specification compliance before quality/security. Record environment limitations and exact evidence reuse.
5. Only after successful integration checks, delete merged local branch refs and archive this chat's completed managed worktrees after preserving needed ignored files. Prune missing registrations. Leave other tasks' dirty worktrees intact.
6. Record final main commit, ancestry coverage, clean primary status and retained worktrees. Keep local recovery archives ignored and recoverable.
