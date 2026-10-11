# R10 review corrections

## Identity and authorization

Parent authorized two accepted independent findings under approved R10, after SPEC/domain then QUALITY review of dc5a562e38af82618e5b63a2fcf4a6a3ba039336 / integrated 3b52c63290d5ee4ae5f207d5c53ccf87255586db. Reports are review-r10-spec.md and review-r10-quality.md here. Root's ten unchanged-input tests were reused during review; no equivalent review rerun was performed.

Implementation is isolated at C:/Users/Administrator/.codex/worktrees/im-runtime-bounds/StarChat, branch codex/im-runtime-bounds, base 214e0887c6b16141c1219249562c6eb9e5c15751. Ownership is the sampler, its test, sampling report and this artifact directory. Cache follow-up 896e8e77 is in its separate tree and is not mixed into this commit. No business/mobile/native sources or shared state ledger changed.

## Correction and RED

- The Synapse counter source in synapse-counter-source.log proves dbevts means events fetched from the database, not events in a sync response. Output schema 2 renames the metric to long_sync_30s_zero_db_fetch_candidates and explicitly disclaims idle/empty-response inference. Neither response bodies nor decrypted content are read.
- The inherited-stdout regression creates a five-second descendant and an owned direct child sleeping ten seconds. On the original source with timeout=1, it returned after 5.125 seconds, failing the under-three-second bound. The descendant writes a completion sentinel, so the fixture proves natural completion, not broad process termination.
- review-fixes-red.log: two intended failures before production edits; one missing accurate output metric, one actual elapsed-time failure. Both are covered by the subsequent 12-test suite.
- POSIX uses nonblocking os.read. Windows uses PeekNamedPipe to read only available bytes with one reader, compatible with Python 3.11. There is no reader thread or buffered read/close lock. Polls sleep at most 10ms, reads at most 8192 bytes, output retains the existing cap, and only the exact direct Popen process can be killed. Reaping has a separate two-second cap, exposed in limits. Cleanup/read failures use fixed error enums without exception text.

## Evidence

- windows-green.log: final source, Windows Python 3.11.11, 12 tests PASS, exit 0, 5.316 seconds.
- windows312-green.log: Python 3.12.10, 12 PASS before formatting and additive cleanup-limit metadata, 5.319 seconds.
- linux-green.log: final source, Linux Python 3.12.11, 12 PASS, exit 0, 5.273 seconds. Read-only repository mount, a dedicated writable fixture subdirectory, --network none, no production credentials or sockets. Image sha256:3036ec25dfb5fcc5120942465788c1e1f2bb3671e28b04d7b3a1db4400ac84f4.
- quality-green.log: Black 26.3.0 and Ruff 0.15.22 checks PASS. The existing Python virtualenv lacks those modules, so the installed explicit D:/python/Scripts executables were used; nothing was installed or altered globally.
- repository-policy.log, deployment-policy.log, template-policy.log: all PASS, exit 0.
- runtime-sample-corrected.json only relabels the previous aggregate. It preserves all original numbers and exact UTC strings and includes original SHA256/provenance. verify_corrected_sample.py and sample-consistency.log verify every service row and line/HTTP/start/completion denominator. The original historical file remains unchanged. PowerShell initially normalized equivalent timestamps to local offset; the exact-string consistency check caught this (sample-consistency-red.log), and the corrected file restores the original strings. No new server sample was taken.
- input-hashes.json binds production/test/report/sample files and log modification times. Raw output is retained locally in ignored raw/; tracked log trailing whitespace is normalized.
- scripts/verify.ps1 exists, but this tree has neither .env nor .venv. Full render/service/mobile gates were not run and no production secrets imported. The standalone diagnostic changes no application, dependency, encryption, permission or schema behavior. Full verify.ps1, native, device, throughput, long-term stability and full R10 completion are not claimed.

## Timing and next step

Work occurred on 2026-10-11 +08. Exact phase completion timestamps are recorded in input-hashes.json from log modification times; active/wait time was not measured separately. Independent original review preceded implementation. Parent should assign another reviewer to the frozen correction before integration; the original reviewer becoming implementer cannot supply independent approval of this fix. R9a review remains a separate prospective task.

Rollback reverts the diagnostic/report commit only. No container, production file, database or resident agent was changed. Historical aggregate evidence is preserved.
