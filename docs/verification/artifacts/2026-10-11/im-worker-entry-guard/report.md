# Permanent worker entry composition gate

2026-10-11, Asia/Hong_Kong. Implementation candidate only; independent SPEC then QUALITY review is next. No deployment, no permanent ops installation, no business service restart.

## Scope and authorization

Root assigned this bounded follow-up after the source-only R9b candidate passed the earlier probe but failed its default Worker/Consumer constructor contract. Approved plan: `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md`, R9/A7-4; role-aware gate ADR and refresh-release runbook remain applicable. Branch `codex/im-worker-entry-guard`, native managed tree `C:/Users/Administrator/.codex/worktrees/im-worker-entry-guard/StarChat`, baseline `8134d9592cc133edf2d0f0d9e5a287ecb36b13c6`.

Owned production files are only `scripts/business_refresh_image_probe.py`, `scripts/business_release_guard.py`, and `tests/infra/test_refresh_release_guards.py`. No business worker/consumer, handler, schema, financial state, refresh/auth policy or deployment code was changed.

## Behavior

The probe verifies the real `worker.py` and installed `app/core/outbox.py` module origins, then checks `main.Worker`/`main.OutboxConsumer` identity against those modules. It constructs `main.Worker(consumer=main.OutboxConsumer(None), handlers={}, worker_id='isolated-entry-composition')`. It never calls `main()`, `run_once`, `run_forever`, claims, or financial handlers for this new check. The existing credential-event and isolated SQLite refresh checks still run separately as before.

Compatibility is decided by each image's actual Worker constructor; the gate does not require new fenced methods on all historical Consumers. A valid older Worker/Consumer pair therefore remains eligible for rollback. A successful construction adds `worker_entry_composition` to the exact proof list, enforced by both probe and release guard. API nine checks are unchanged; worker's previous eight checks remain, plus this ninth check. Old proof documents lacking the new check fail closed.

## Test-first evidence

| Stage | Command / evidence | Result |
| --- | --- | --- |
| Initial environment mismatch | `python -m pytest ...`, `preflight-wrong-python.txt` | Wrong default Python lacked coincurve; preserved as an environment failure, not accepted RED |
| Intended RED before any production edits | `py -3.12 -m pytest tests/infra/test_refresh_release_guards.py -q -k 'legacy_proof_without_entry_composition or new_worker_with_old_consumer_contract or entry_binding_or_origin_drift or runs_runtime_event'`, `red.txt` | Exit 1, 7 expected failures, 33 deselected; incompatible real Consumer contract returned the old successful proof |
| Focused GREEN | `py -3.12 -m pytest tests/infra/test_refresh_release_guards.py -q`, `green-focused.txt` | Exit 0, 40 PASS, 13.32s |
| Complete infra suite | `py -3.12 -m pytest tests/infra -q`, `green-infra.txt` | Exit 0, 915 PASS / 20 conditional SKIP, 44.96s |
| Skip clarification | `py -3.12 -m pytest tests/infra/test_synapse_recovery_postgres.py -q -rs`, `infra-skip-reasons.txt` | Explicit isolated PostgreSQL DSN absent; skips are not passes |
| Static | Three changed Python files parsed with `ast.parse`; scoped `git diff --check` for those files | PASS |

Failure injection removes the three fenced completion methods from the real imported Consumer class while retaining the real new Worker. Additional tests substitute each main alias or module origin and verify rejection. The success case traps worker loop/claim execution and verifies the Consumer receives no session factory. Original worker refresh/event assertions and API nine ASGI assertions remain.

`environment.json` identifies Windows and Python/pytest versions. `scripts/verify.ps1` was preflighted but not launched: its mandatory `scripts/init_matrix.ps1 -RenderOnly` stage requires `.env`, absent in this isolated tree. No production secrets were copied and no successful full-repository verification is claimed. The bounded infra gate and actual final-image checks cover this change; root owns broader integrated gates.

Raw pytest failure transcripts intentionally retain pytest's indentation on blank lines. Unscoped staged `git diff --check` reports trailing spaces only in these two raw transcripts (`red.txt`, `preflight-wrong-python.txt`); changed code and other artifacts have no such findings.

## Actual immutable-image matrix

All four guard runs use the changed production `verify_image` function. `image-compatibility.json` records actual argv, exit, digest, proof and both uploaded script byte hashes. `run_image_compatibility.py` is the exact temporary host runner. The earlier `image-compatibility-initial.json` is retained; the final rerun adds actual guard argv and an exact rejected-stage diagnostic requested by root.

| Image combination | Immutable image | New guard | Default import composition |
| --- | --- | --- | --- |
| Old Worker / old Consumer | `sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf` | exit 0, all 9 worker checks | exit 0 |
| New Worker / new installed Consumer | `sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a` | exit 0, all 9 worker checks | exit 0 |
| New Worker / old installed Consumer | `sha256:13f3c67b2f84b09a659af16a5308917c3358071f1fada9cb66e7c9af6b2d9cd7` | exit 1, rejected | exit 1, incompatible composition |
| Unchanged API | `sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3` | exit 0, unchanged 9 API checks | Not a worker |

The separate failure-stage diagnostic verifies the failed candidate raises the exact missing `mark_claim_succeeded` constructor TypeError from `/opt/business-worker/app/worker.py`, called by `verify_worker`. It emits only a fixed check name and boolean. Thus rejection is specifically the requested `worker_entry_composition` failure, not an unrelated import or refresh failure.

Default composition probes use `python -c` in the image's unchanged working directory, no PYTHONPATH, and assert actual `main.py`, `worker.py` and installed Consumer paths before constructing. All containers use network none, read-only root, bounded tmpfs/memory/CPU/PIDs, dropped capabilities and no-new-privileges. No production environment, data, DB, token or credential mounts. Only synthetic protocol data are generated. Containers are removed by exact random name even on timeout.

## Timing and handoff

Preparation/ownership/native tree began approximately 15:29 +08; start is approximate because the original wall-clock start was not sampled. Intended RED completed 15:34:44; focused GREEN completed 15:35:36. Infra and first image checks ran in parallel; final argv/stage evidence completed approximately 15:40. Exact artifact modification times are recorded in `manifest.json`; test durations above are pytest output, not estimated wall time.

Temporary non-installed server verification path: `/opt/starchat/releases/im-worker-entry-guard-20261011-2a6de21d/`. It contains only the two candidate scripts and runner, and can be used for independent isolated rechecking. It is not `/opt/starchat/ops/refresh-guards/` and no Compose operation was invoked.

Next executable step: root independently reviews SPEC then QUALITY, integrates the frozen commit, and separately handles any authorized paired-file ops installation with pre-state SHA compare, private backup, atomic replacement and fresh paired SHA validation. Do not publish only one script: proof lists must move together. Root should update the runbook's worker count from eight to nine and document entry composition when integrating; that shared runbook is outside this task's file ownership. Broader runtime liveness, active-handler lease renewal, exactly-once effects and financial behavior are not proven by constructor compatibility.
