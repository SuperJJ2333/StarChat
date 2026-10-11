# R9b r2: actual default import and paired-overlay review

Reviewer: `/root/fix_scheduler_r6`, independent of the deployment-script author. Root's files and services were not modified. Review commands read local artifacts/Git and ran AST-selected mocks only; no deploy top-level, Docker, database, network or real process signal was executed by this reviewer.

## Previous finding retained

r1 candidate `13f3c67...` failed and the deployment receipt records successful automatic rollback after a settled switch. Its Worker loaded the old installed `app.core.outbox`, while the overlay changed only `/opt/business-api/app/core/outbox.py`. The earlier pytest gate overrode `PYTHONPATH` and therefore tested a different import path from production. My r1 review checked the explicit copied bytes and switching failure boundaries but missed this installed-package resolution gap. The original report is now annotated; its historical PASS is not a deployment-readiness claim for r1.

The frozen Worker Dockerfile explains the distinction: it installs `/opt/business-api` with pip, then sets `/opt/business-worker/app` as WORKDIR and runs `python main.py`. The Worker correctly rejects an incompatible Consumer rather than silently using unfenced completion.

## Exact r2 inputs

- `prepare.py`: `3b2dde8b075154c761cb3180556e9927bb9fad2adc0528ef53659c76b7ac98b5`.
- `deploy.py`: `1dd4023f4f63fedf2c1080013e5535838a3afda95330a58cbe4cc01f5906ea73`.
- `default_entry_probe.py`: `63c686248b66a867aaf2d00e16528323f69ece94b01e8f4b44ce20b1cd2b00c8`.
- Prepared candidate: `sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a`.
- Base/rollback: `sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf`. API remains `sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3`; schema remains `0095_wallet_source_alerts`.

## SPEC inspection

The release root and image tag move to `im-worker-fence-v2-20261011`. The same reviewed Consumer bytes now go to both `/usr/local/lib/python3.12/site-packages/app/core/outbox.py` and `/opt/business-api/app/core/outbox.py`. All three payloads equal their corresponding Git bytes at domain-reviewed commit `9920947c34e6c41a050a1fbb1d9cc7d7ac882749`; business code is unchanged. Preparation checks three old live hashes and three new payload hashes. The unchanged generic deploy/rollback loop checks all three destinations and the receipt retains all three. API/container/config/schema boundaries are unchanged.

The default-entry probe imports `main`, `worker` and `app.core.outbox` without adding a source directory. It rejects a nonempty PYTHONPATH, checks the actual installed Consumer and worker `__file__`, proves `main.OutboxConsumer` and `main.Worker` refer to those exact objects, checks both Consumer copies plus Worker hashes, and constructs `main.OutboxConsumer(None)` and `main.Worker(..., handlers={})`. It invokes neither `main.main`, `run_once`, `run_forever`, completion handlers nor a session factory. The reviewed constructors perform no DB/network operation in this use.

## QUALITY and verification

Independent local replay: **11 fault-boundary cases PASS** at the new deploy SHA; **8 triple-file deploy/rollback cases PASS**, including independent rejection of a wrong Worker, installed Consumer or source-copy hash. The source comparison confirms r2 deploy changes only the release path, so uncertain-switch handling is intact: outer timeout, cleanup/wait error or nonzero guard result withholds automatic rollback; only a settled switch with a failed postcondition may use guarded rollback. See the scripts, JSON results and r1→r2 diffs in this directory.

Root's `validation-result.txt` records the same new probe rejecting the source-only candidate (exit 1), accepting the installed-overlay candidate (exit 0), and printing the actual installed Consumer path plus all expected hashes. The default-import candidate tests report **49 PASS / 1 explicit PostgreSQL fixture SKIP / 1 known active-handler expiry XFAIL**, exit 0, 0.79 seconds; protocol candidate/rollback validation reports exit 0. These are reused execution records, not independently rerun native/container tests. No skip/xfail is counted as a pass.

Final invocation-provenance check: `default-runtime-receipt.json` SHA256 `0791e11b4b97ccd043626f7640834a51e257bbd7a5cf2686298ff213ec0482e6` and its execution script `validate_default_runtime.py` SHA256 `1d0db7583f9ee2f61824306581be17b373b69b6910dedd171a347e5cb9bde41e` were inspected. Both commands use the exact `bfde7c86...` digest, `--network none`, `--read-only`, bounded synthetic `/tmp`, and no cwd override or PYTHONPATH injection. The probe runs `--entrypoint python IMAGE -c "exec(open('/probe.py').read())"`, preserving the default import origin. Pytest appends only the hash-bound tooling ZIP and asserts the installed Consumer path before `pytest.main`; plugin autoload is disabled. Both exit 0 with empty stderr. The tooling ZIP hash matches and its contents contain no `app/`, `main.py` or `worker.py` override. Programmatic consistency checks are recorded in `default-runtime-provenance.json`.

**Final SPEC → QUALITY verdict: PASS for this exact r2 overlay, default-entry probe and preserved switching boundaries.** The default-entry evidence now exercises the installed Consumer used by production; the prior /opt-only gate failure is addressed without changing business code or weakening Worker validation. The startup probe is an explicit reviewed prerelease gate whose receipt is bound here to the candidate image, rather than an inferred result from file-copy hashes or an overridden test environment.

The same limitations still apply: this is r2 startup/overlay validation, not proof of exactly-once handlers or lease renewal. Default constructor probes do not execute the production handler loop; post-deployment health, runtime imported-file hashes and production postflight remain required. This review does not erase r1's failed deployment or convert the successful rollback into a successful r1 release.
