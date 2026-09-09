# Branch and worktree audit — 2026-09-10

Read-only Git audit in `.worktrees/integrate-main-20260910`, before any cleanup. Only this evidence file was written. No fetch, merge, checkout, detach, branch deletion, staging, commit, worktree move/removal, or content reconciliation was performed. Live remote refs were checked with `git ls-remote --symref origin HEAD refs/heads/*`; they matched existing remote-tracking refs.

## Ancestry snapshot

Main: `094a823f9a26f8b11d723c8fe6143ad460892dc6` (`merge: inherit debug 2080 account switch fixes`). All listed feature tips are already ancestors of main. There are **zero committed changes on any listed local or remote feature ref absent from main**, including iOS compatibility and wallet. Counts use `git rev-list --left-right --count main...REF`; behind means commits reachable only from main, ahead means commits reachable only from the ref.

| Ref | Full tip | Behind main | Ahead main |
| --- | --- | ---: | ---: |
| local codex/integrate-main-20260910 | 2ff3618fad930baeb87545114a3628a80b53f7fc | 4 | 0 |
| local codex/ios-0353-background | 21f99300521066aad140d441d35a25c19a7e0b39 | 98 | 0 |
| local codex/mobile-parity-20260909 | 5fbb295339413f38b8e50797a853345da94c11a2 | 12 | 0 |
| local codex/redmi-polish-20260909 | 05d40c2da410b540f59079cdd0f0c80084ef1f0b | 18 | 0 |
| local codex/video-menu-redmi-20260910 | 5ad86aa02ab91c9fd7f71bf29304de8109df77c7 | 3 | 0 |
| local codex/wallet-safety-mi6 | 1bc3fe59e9263069ec20aaed3d1b8ab47028bad3 | 118 | 0 |
| origin/codex/ios-compatibility | f0e594525144a5f4f46379a7c86b13922ad00612 | 106 | 0 |
| origin/codex/mobile-parity-20260909 | 5fbb295339413f38b8e50797a853345da94c11a2 | 12 | 0 |
| origin/codex/wallet-safety-mi6 | e454bf59ccf2a1eede3ff25f047e732068055bbc | 120 | 0 |
| origin/main | be14e743348cb9660c005b81c2ff827515b9faff | 31 | 0 |

`git log --format='%h %s' main..REF` was empty for every ref. Remote default is already `refs/heads/main`; preserve it. Push and verify the final main tip before deleting remote feature refs so their retained history is on remote main, not merely local main.

## Worktree snapshot

Counts are `git status --porcelain=v1 --untracked-files=normal` entries, so untracked directories count as one entry; ignored files are outside this snapshot. All worktrees had zero staged entries. Paths below are relative to `D:/pythonProject/outsource/StarChat` except the root row.

| Worktree | Checked-out branch | Modified tracked | Untracked entries | Recommendation |
| --- | --- | ---: | ---: | --- |
| repository root | codex/wallet-safety-mi6 | 98 | 410 | Retain branch and worktree; active media work and extensive uncommitted content. Do not switch, detach, reset, clean, or remove. |
| .worktrees/consolidate-20260908 | codex/mobile-parity-20260909 | 0 | 2 | Retain artifacts. If confirmed inactive, detaching at the same tip preserves files and allows branch deletion. Do not remove the directory. |
| .worktrees/integrate-main-20260910 | main | 0 | 2 | Active integration worktree; retain. Counts precede this report and concurrent implementation. |
| .worktrees/redmi-polish-20260909 | codex/redmi-polish-20260909 | 0 | 0 | Clean; if inactive, detach at its exact tip then delete the merged local branch. |
| docs/verification/artifacts/2026-09-08/ios-0353/source | codex/ios-0353-background | 6 | 5 | Retain dirty branch and worktree; uncommitted changes require separate reconciliation. |

Root untracked entries by top-level directory: `.playwright-mcp` 1, `apps` 31, `docs` 150, `frontend` 35, `infra` 2, `scripts` 6, `services` 89, `tests` 95, `third_party` 1. These include media, wallet, frontend, deployment, tests, and evidence. This audit does not assert that dirty files are represented in main; ancestry only proves committed history containment.

Consolidate worktree's two untracked entries are `docs/verification/artifacts/2026-09-09/` and `docs/verification/artifacts/2026-09-10/`. Main worktree's entries were the new conversation-state implementation plan and the 2026-09-10 artifacts directory.

Dirty iOS tracked files: `direct_chat_controller.dart`, `media_cache.dart`, and `voice_playback_controller.dart` under `apps/mobile_flutter/lib/features/matrix/`; `apps/mobile_flutter/pubspec.lock`, `apps/mobile_flutter/pubspec.yaml`; and `apps/mobile_flutter/test/features/matrix/voice_audio_source_test.dart`. Untracked: `apps/mobile_flutter/assets/diagnostics/`, `apps/mobile_flutter/integration_test/`, `apps/mobile_flutter/test/features/matrix/direct_chat_sync_failure_test.dart`, `apps/mobile_flutter/test/features/matrix/video_playback_extension_test.dart`, and `scripts/generate_ios_compatibility_fixtures.py`.

## Exact cleanup candidates

Recheck tips and worktree status immediately before acting; another task can change them. No cleanup commands below were executed by this audit.

1. Unchecked-out, merged local refs can be deleted with `git branch -d codex/integrate-main-20260910 codex/video-menu-redmi-20260910`.
2. Clean inactive Redmi worktree can be detached at `05d40c2da410b540f59079cdd0f0c80084ef1f0b`, then `git branch -d codex/redmi-polish-20260909`. Retaining its directory also preserves any ignored local outputs outside this status audit.
3. If consolidate is inactive, detach it at `5fbb295339413f38b8e50797a853345da94c11a2`, retain all files/artifacts, then `git branch -d codex/mobile-parity-20260909`.
4. After final main is pushed and live remote containment verified, remote refs `codex/ios-compatibility`, `codex/mobile-parity-20260909`, and `codex/wallet-safety-mi6` are history-safe deletion candidates. Use conditional deletion with expected hashes from the table to prevent deleting a concurrently updated remote tip. Retain local dirty wallet and iOS branches regardless of remote cleanup.
5. Retain `main`, remote `main`, remote default `HEAD -> main`, local `codex/wallet-safety-mi6`, and local `codex/ios-0353-background`.

No unique committed merge work remains in the audited feature refs. Remaining preservation work concerns dirty worktrees and concurrent work, not unmerged commit ancestry.
