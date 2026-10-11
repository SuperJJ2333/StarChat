# R10 independent QUALITY/security review

This review followed review-r10-spec.md on frozen dc5a562e / integrated 3b52c632. The unchanged ten root tests were reused. The script uses fixed Docker commands and sanitized scalar output, caps bytes and lines, keeps identifiers only transiently, exposes truncation/timeout and missing-data states, and never persists raw logs or prints stderr. Review found no secret output, writable Docker command or denominator loss in the inspected fixtures/sample.

Outcome: changes required, P2 at run_bounded cleanup. A descendant retaining inherited stdout can keep the buffered reader blocked after the direct process is killed. reader.join(timeout=1) is bounded, but the following process.stdout.close() waits for that reader's lock, so total runtime is not bounded by the configured timeout plus fixed cleanup.

A controlled Windows/Python reproduction spawned one direct Python child which spawned a six-second sleeping descendant inheriting stdout, printed ready and slept ten seconds. run_bounded(max_bytes=128, timeout=1) returned after 6.172 seconds, error=timeout, bytes=0. The descendant was allowed to exit naturally. The earlier simple timeout test lacks this inherited-pipe condition. This is a demonstrated collector defect, not evidence that the saved production sample encountered it.

Use a bounded/nonblocking read path that does not wait for a foreign holder to close the pipe; kill only the exact directly owned Popen process, never a process-name sweep or unrelated descendant. Add a deterministic inherited-stdout regression proving early return, preserved timeout visibility and that the descendant survives to its own completion. Keep byte caps, partial-line reporting and sanitized errors.

The saved sample's line/request totals were consistent, all commands reported success, and no truncation flags were set. Its runtime image/status and instantaneous stats do not establish RSS peaks or capacity. Parent accepted this finding and authorized correction on 2026-10-11. This review reports the original frozen input only; independent review is needed for this reviewer's subsequent fix.
