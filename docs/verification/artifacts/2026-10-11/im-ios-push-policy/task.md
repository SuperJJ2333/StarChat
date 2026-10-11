# R5b Sygnal iOS scheduled DND

## Recovery entry

- Authorized scope: root delegated approved 2026-10-11 IM reliability plan R5b, send-time ordinary iOS sound policy and isolated fixture/build only. No production credentials, real APNs notification, deployment, shared Compose edit, client edit or package release.
- Worktree: `C:/Users/Administrator/.codex/worktrees/im-ios-push-policy/StarChat`; branch `codex/im-ios-push-policy`; base `5c83a08a09b985146bc507a1608cb2153d361e48`.
- Files owned: `services/sygnal/`, `tests/sygnal/`, this evidence directory. Client wire/Swift owner is `review_r1_r2` in `im-pusher-reconcile`; root owns integration/release. R1–R4 review records were completed separately and are not changed here.
- Design frozen with the client owner: the exact v1 object and semantics are in `services/sygnal/README.md`, matching the client's `dnd-wire-design.md` (hash recorded). The approved main plan is in the integration tree under `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md`.
- Status: implementation and isolated candidate verification complete, awaiting independent specification/domain then quality review. Source freeze/commit supplied in handoff. Last observed local time 2026-10-11 11:16:35 +08.

## Implementation and rationale

The preexisting Sygnal path receives the pusher's static `default_payload` and constructs APNs messages without a send-time schedule. The patch adds a stateless policy immediately before NotificationRequest in `_dispatch_request`, so retries use their actual UTC dispatch time rather than the original event time. It deep-copies each outgoing message and only removes `aps.sound`; a retry across the end of DND retains the unmodified source sound. Alert, badge, payload truncation, response/rejection mapping and retry behavior remain upstream code. Existing send/rejection logs in this touched module are sanitized to remove device/room/event values; the added log uses only a fixed reason enum.

Strict field/version/type/range/IANA validation fails closed to a silent visible notification. Missing policy remains legacy; explicit non-alert types including VoIP are unchanged. The interval is half-open and wraps midnight, with equal endpoints disabled; UTC-to-zone conversion handles DST folds and gaps without constructing nonexistent local times. Revision is validated identity metadata, not a server-maintained source of preference authority. No push token, body, address, key or policy value is logged.

The helper and one licensed upstream file form a minimal overlay over exact Sygnal 0.15.1. Original source SHA256 `e87d32765b4d3f1cd24102ad25f87f1f4a53e8cd3666cc376798d915ab0131b9` matches both official tag and existing base container. Dockerfile checks it before copy; explicit base digest is `0e3ab79e04371964916f428a99b7fab19f23cbb16089112c4e7d8874c8f301ba`. Apache LICENSE bytes remain identical. No global site-packages, cache, global Git setting, dependency version or production configuration was changed. Local build and test containers have network disabled; fixture constructors bypass certificate setup and replace only APNs transport/UTC time.

Additional review during implementation found `zoneinfo` accepts `localtime` and `posixrules`, which are server-specific files rather than valid client IANA identifiers. Two new failing cases proved that these could accidentally retain sound. The parser now explicitly rejects them, along with posix/right/path-shaped names, preserving the frozen IANA contract.

## Evidence and commands

All shell commands: PowerShell7 UTF-8 console/pipeline, `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`. Docker host29.8.2 on Windows10; candidate executes Linux Python3.11.10, matrix-sygnal0.15.1, aioapns3.2, Twisted24.3.0. `environment-final.json`, `image-id.txt` and `input-hashes.json` bind final image/source and client fixture inputs.

Base image alias in commands below means `matrixdotorg/sygnal@sha256:0e3ab79e04371964916f428a99b7fab19f23cbb16089112c4e7d8874c8f301ba`; candidate alias means `starchat/sygnal:im-ios-policy-20261011`. Every run used `--rm --network none`; test files were read-only bind mounts, with no production data/config mount.

| Gate | Exact operation after image selection | Result | Evidence |
| --- | --- | --- | --- |
| Initial behavior RED, base | `--entrypoint python BASE /tests/ios_policy_contract.py` | exit1;10 methods/34 failing subcases; no setup error | red.log |
| Candidate build | `docker build --network none --pull=false -t starchat/sygnal:im-ios-policy-20261011 services/sygnal` | exit0 | build-final.log |
| Initial GREEN | `--entrypoint python CANDIDATE /tests/ios_policy_contract.py` | exit0;10 methods | green.log |
| Reserved-zone RED, first candidate | same script plus `PolicyContract.test_present_invalid_policy_is_silent_not_rejected` | exit1;2 failures for localtime/posixrules | reserved-zone-red.log |
| Final frozen GREEN | `--entrypoint python CANDIDATE /tests/ios_policy_contract.py` | exit0;11 methods, including both retry boundary directions | green-frozen.log |
| Upstream adjacent regression | `--workdir /work --entrypoint python CANDIDATE -m twisted.trial --temp-directory /tmp/policy-trial tests.test_apns tests.test_apnstruncate` | exit0;19 tests | upstream-frozen.log |
| Real Flutter static payloads | `--entrypoint python CANDIDATE /ios_sound.py /fixture/flutter-sound-payloads.json` | exit0;2 cases, real NotificationRequest with final APNs double | client-static-frozen.log |
| Repository/deployment policy | `pwsh -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1`; same `Test-DeploymentPolicy.ps1` | each exit0/PASS | session tool output |
| AST/patch | Python ast.parse of source/test; staged diff-check | recorded at freeze | session tool output |

The final image ID is `sha256:01d1196db73d56449fa2a1c6c62f846ddfb14ceca9c6408fe38f8b835bbc0141`; internal apnspushkin SHA is `134f9f9da53750fdaaa00dacc0e1afb889bf976075c4301270e24a31595c189d`, helper SHA is `cab22f7376c870cb16a538196a6b235807c88c0f819e3d717249c0306e03102a`.

The standalone fixture covers start/end/midnight, a same-day interval, disabled/equal windows, half-hour zone, both DST-fold instants and spring gap, strict invalid input, static-off dominance, legacy, VoIP/non-alert isolation, unset default push type, full/event-id-only builders, per-attempt time and immutable defaults, and fixed logging without synthetic sensitive values. Expected injected 503 traces appear in the retry tests and upstream tests; they are assertions of retry behavior, not unexplained failures.

## Limits, setup issues and timing

The first metadata probe asked for distribution `sygnal`, but upstream packages itself as `matrix-sygnal`; the corrected probe records the real version. This was setup, not a behavior RED. Docker Desktop's pipe disappeared once during the final test launch; `daemon-unavailable.log` preserves exit1. Read-only engine inspection then confirmed it had recovered, and the unchanged test was rerun successfully. No daemon reset or global changes were made.

Unittest's trailing spaces in two RED logs were normalized for repository diff-check; the complete line content/failures are retained and the original raw copies remain locally under this evidence directory. Directory-local attributes keep Dockerfile/evidence LF and upstream LICENSE bytes stable across Windows/Linux. No global line-ending setting was changed.

`scripts/verify.ps1` was read/preflighted: this clean worktree lacks `.env`, needed by its render stage. Full verify was not run or claimed passed, and no production secrets were imported. Focused Linux tests and repository/deployment policy checks passed; parent coordinates applicable integrated gates. No real APNs send, on-device playback/Focus/silent switch, production config/image change, device quota or package release occurred. E2EE event-id-only metadata cannot prove an attention exception, so no bypass is inferred or transmitted.

First recorded setup timestamp11:01:32 +08, source/contract/container preflight through11:05; initial real RED and implementation through11:11; final boundary expansion, daemon recovery and frozen regression through11:16. Exact individual start times and active/tool split were not captured; no fabricated additive elapsed total. Initial GREEN0.096s; final fixture0.224s; final upstream19 tests0.180s. Docker wall times include startup and are not test CPU times.

## Handoff and rollback

Next: independent specification/domain review, then quality/security review, then root-owned integration/rollout. Recheck the then-running Sygnal image/config and preserve private credential mounts before building/switching only this service. Existing class/config routing is unchanged. Freeze rollback image/config and compare unrelated container IDs; rollback has no database migration or pusher deletion. Server must be deployed before claiming the client DND window is enforced. Installed source hashes, unauthorized gateway behavior and ordinary/VoIP dispatch fixtures remain required release evidence; real device audible/visual results remain separate.
