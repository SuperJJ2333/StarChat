# Revised installer review — one remaining restoration-buffer gap

Input SHA256 `55d1b15ae56a9131f526cf793592cab9262f6ebe028e7ff9daee4abbadbf9316`, exact copy `install_pair_r2.py`, independently reviewed 2026-10-11 15:53 +08. Root remains author; no installer edits by reviewer.

SPEC: cached preflight source/old byte validation, backup flush/fsync/readback, and ownership-aware temporary cleanup address the initial findings. All original 17 test cases pass unchanged except supplying the newly used real `os.fstat` in the platform mock. A newly added changed-temp-owner test also passes.

QUALITY: one remaining P1 in the same restore-buffer boundary. Before rollback, the revised code hashes every backup, then later reads each backup again for `atomic_bytes`. A deterministic test changes the probe backup after the guard file's restoration; it then installs `LATER_BACKUP_DRIFT` into the probe target. Output: **18 PASS / 1 FAIL**, exit 1, 0.95s (`boundaries-r2.txt`). This is the same verify-buffer/use-buffer mismatch fixed for staged sources, now on restoration.

Minimum correction: use already-verified immutable `old_bytes[name]` as `atomic_bytes`'s restore payload. Keep the all-backup integrity gate so corrupted backups discovered before restoration still stop with `manual_inspection_required`. This requires no new global lock or claim of protection against arbitrary malicious concurrent root changes.

Tests still mock Docker, flock and POSIX metadata/directory-fsync and use only disposable local files. No install, service operation, business handler, DB or production credential is accessed. A passing mock review will approve only the bounded installer behavior; it will not itself prove a real installation, power-loss recovery, or atomic replacement of the two-file pair as a single filesystem transaction.
