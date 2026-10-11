# Independent installer SPEC then QUALITY — PASS

Final reviewed installer SHA256: `cc9b1de8cd36b8cca4d853abca995f2de7ee964aca457c041f230befb6c4e8c2`, exact bytes `install_pair_r3.py`. Reviewed 2026-10-11 15:55 +08. Root authored every installer revision; this reviewer only added independent tests/reports and copied exact review inputs. No root source edits, server installation or Docker execution by this reviewer.

## SPEC

PASS for the authorized bounded installation. Exact old/new paired SHA preconditions are retained, source and old target buffers are validated once and cached, backup bytes come from validated old buffers with file flush/fsync and hash readback, and mode/uid/gid metadata is recorded for restoration. Install uses only the validated source buffers. Each file replacement is atomic; the pair as a whole is not a single filesystem transaction, and both mixed old/new check-list combinations reject.

The installed guard path is loaded for the existing three immutable images: current worker `bfde7c86…`, rollback worker `18a88c4d…`, API `a935b414…`. No Docker Compose or service restart/deployment command is introduced. Before/after container name-to-ID maps must agree. `changed` includes a successful replace followed by failed directory fsync. Recovery requires current targets be known old/new bytes and every backup pass its original hash; it replaces only this attempt's exact new bytes using the already-validated old buffers.

## QUALITY

PASS with no remaining blocking finding in the scoped review. Initial three findings and the residual r2 restore-buffer gap are fixed. r3 differs from r2 by only the restore payload changing from a fresh backup read to `old_bytes[name]`; the all-backup integrity gate remains. Temporary cleanup starts only after this attempt's successful create and retains a changed inode/device or pre-existing foreign file. External target drift stops recovery for manual inspection rather than overwriting it.

All **19 cases PASS**, exit 0, 0.70s, in `boundaries-r3.txt`. Original assertions remain; the only fixture adaptation is forwarding newly used `os.fstat` to the real platform function. Cases cover source/target pre-state, success/metadata/proof list, proof failure, second replacement failure, directory fsync after replacement, target drift, identity drift, four pre-replace failures, staged source drift, corrupted backup, foreign temporary file, both mixed guard/probe directions, backup drift between restores, and changed temporary ownership.

Evidence chain: initial installer `14f26696…` had 11 PASS / 6 FAIL; r2 `55d1b15a…` had 18 PASS / 1 FAIL; final `cc9b1de8…` has 19 PASS. Exact inputs, tests, logs and rejected reports are retained rather than overwritten. Raw pytest failure transcripts contain framework-generated trailing spaces; no product code is changed in these review commits.

Command: `py -3.12 -m pytest docs/verification/artifacts/2026-10-11/im-worker-entry-guard/install-independent/test_install_boundaries_r3.py -q --basetemp docs/verification/artifacts/2026-10-11/im-worker-entry-guard/install-independent/tmp-r3`.

The tests use real disposable Windows files but mock Docker, flock, chmod/chown and directory-fsync. They prove control flow and buffer/ownership behavior, not Linux permission enforcement or power-loss durability. The exact guard/probe pair already has actual isolated four-image proof in the parent artifact directory. Root must still bind the installed Linux bytes, backup permissions, image proofs and unchanged container IDs to the installation receipt. This review does not claim installation already occurred, automatically approve arbitrary future bytes, or claim resistance to arbitrary concurrent malicious root writes/process termination.

Approved candidate pair remains probe `2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15` plus guard `46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b`. The installer may not be reused blindly once its receipt exists.
