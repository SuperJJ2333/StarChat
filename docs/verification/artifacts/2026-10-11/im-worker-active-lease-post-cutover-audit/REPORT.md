# Independent production post-cutover observation

Result: **STRUCTURAL_PASS_LOG_REVIEW_REQUIRED**. All nine read-only checks completed successfully. The bounded log sample matched one warning-category line; its cause remains unidentified after the separately authorized classification below. Root was notified at each boundary and querying stopped. No recovery was attempted. Do not restate this result as an unqualified all-clear.

Authorization: root explicitly reported the worker switch settled PASS and requested one execution of frozen plan246f42. Android publication was reported complete by root; this audit did not independently repeat Android checks. Only this agent's verification directory was written locally. No root/shared task file was edited.

## Execution identity

- Frozen audit: `246f42db2c537b4710b7edbfbdebdc711629dfe1`; script SHA256 `8c4fb0112b1394598ae05e44a6dfe78999e30f0a94d97f1ac4ac39ece487aa15`, verified before execution.
- One jumper wrapper call, exit0. Local interval `2026-10-11T10:42:12.2668577Z`–`2026-10-11T10:42:15.2940176Z` (3.03s). Server observation timestamp `2026-10-11T10:42:11.726982+00:00`. These are distinct machine clocks, not a cross-host duration measurement.
- Actual settled receipt: started `2026-10-11T10:39:52Z`, completed `2026-10-11T10:40:17Z`, stagePASS.
- Worker ID `db5d65ff01ae55a878fe1a2231e25954df84f9aec8bfdabfacd90c535dae0b7c`; candidate image `sha256:abda33f8fe5bb4abca45464a5d300fff8981a8b68908be1b64f6e3ee0d8a0e7f`.
- Remote script was supplied in-memory through the existing jumper wrapper. No upload, remote file write, temporary container, guard execution, deployment, service restart, SQL mutation or business operation occurred. Existing-container Python used `-B`; schema query used READ ONLY/connect3s/statement5s/outer12s bounds.

## Observed checks

| Check | Observation |
| --- | --- |
| Worker | Exact reported new ID and candidate image; running/healthy; restart0; OOMfalse |
| API | Original ID87c627… and imagea935… unchanged; running/healthy; restart0; OOMfalse |
| Five runtime files | Exact reviewed mainf320…, workerb59f…, newlease37ae…, both installed/source Consumer8306… |
| Other containers | All60 before/after; no unrelated name/ID drift; running35 recorded separately |
| Permanent guard/probe | Exact46d98…/2a6de… content hashes |
| Schema | `0095_wallet_source_alerts` present |
| HTTPS readiness | `/api/v1/health/ready` returned200 with certificate verification |
| Worker log sample | Since switch start; tail cap2000; 10 combined-stream split lines counted; warning-category1, other configured categories unmatched |

Full non-sensitive identities and boolean checks are in `post-cutover-result.json`; command identity, observation interval and exit code are in `execution-metadata.json`. The combined-stream line count is a sampling counter, not a count of distinct application events. No raw log lines or exception details were printed or saved. Warning matching is lexical and does not itself establish a defect. Root must classify the remaining warning using its authorized evidence before recording an unqualified log conclusion.

This short snapshot verifies deployment identity and observed runtime health. It does not prove that a production handler ran longer than five minutes, cover future faults, or establish external exactly-once semantics. Active-handler behavior remains supported by the separate reviewed isolated source/PG/default-image evidence and the bounded15-minute policy; financial/external side effects still rely on the existing idempotency contract. No financial handler, schema, historical DEAD record, E2EE material or audit boundary was accessed or changed.

## Separately authorized warning classification

After receiving the initial strict result, root authorized exactly one additional bounded log classification with four warning categories and static old-source comparison. The original `post-cutover-result.json` and `execution-metadata.json` were not overwritten. The supplemental `classify_warning_readonly.py` SHA256 is `8ef74cae751f8a1e150dc2665f863dd157683cb3979d5f1a1bf677f4e999a215`; local synthetic allowlist/unknown-category/sensitive-marker checks passed before the call.

The additional jumper call exited0, server observation `2026-10-11T10:45:27.374404+00:00`. It read the exact new worker ID's logs once, since10:39:52Z, tail cap2000/deadline12s, and classified15 nonempty combined-stream lines. Results: custody-not-configured/maintenance-skipped0; maintenance-task-failed0; outbox-reap-failed0; **other-warning1**. Traceback, error and all four lease-failure reason counts were0. Its exact result is **UNKNOWN_WARNING_REQUIRES_REVIEW**, not an approval to ignore the warning. Raw lines, mode, exception and identifiers remained only in memory and were not printed or saved. No further lookup was attempted after notifying root.

`warning-template-git-proof.json` independently confirms the suggested custody template appears in old main183 and new main184. The old Git blob SHA03b74… exactly matches the known rollback main; newf320… matches the candidate. That proves template ancestry only, not a prior runtime occurrence, desired financial configuration, or the cause of this unmatched warning. No production financial module was imported and no secret/configuration was read. Supplemental receipts are `warning-classification-result.json` and `warning-classification-metadata.json`; this warning remains an explicit follow-up for root.
