# R9b-2 deployment preparation

Status: candidate built; local fault boundaries and actual-image checks passed; independent deployment review pending. **No production worker switch has been run.** A later cutover requires Android publication and root's renewed live drift/authorization check. No product source changed in this directory's commits. Core scripts frozen at `77ca608c7d98a147a2af4d657c2cb8c82be9e495`; subsequent additions are staging/check wrappers and evidence.

Source: `c3dd314212c73414c5ab371b4363e077bc9104c2`. Plan: `PLAN.md`. `assemble.py` extracts Git bytes, never the dirty workspace. Five destinations and old/new SHA are in `payload-spec.json`; main/worker/Consumer old Git bytes equal root's 09:25:25Z runtime snapshot. New `lease_renewal.py` old state is literal `ABSENT`.

Fresh read-only observation: `live-preflight.json`, 2026-10-11 09:49:37Z, jumper exit0. API `sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3`; worker and rollback `sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a`; worker ID `db3001d69e9425b16ad4eda5b81cd99c71232bf85cc0e6251c86008ee03b118f`; both healthy, schema0095. Compose source layers and hashes recorded without env/DSN output. This is an observed baseline, not permission to skip a later drift check.

Permanent guard `46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b` and probe `2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15` are inherited and hash-checked; neither is installed or replaced by these scripts.

## Script behavior

- `prepare.py`: inherits reviewed v2 freeze/build. Exact existing API/worker baseline, env comparison retained privately, worker-only source overlay, network-none Docker build, immutable candidate ID, separate API/worker candidate/rollback Compose. Only release-private files and a new candidate image are written. Five old source states checked before build; payload new hashes checked. Private inspect/Compose remains server-side mode0700/0600.
- `deploy.py`: prepared only; requires explicit `--execute-after-android-publication`. This flag is operator acknowledgement, not proof of publication. Before guard call it rechecks exact live image/container/runtime/Compose/source state and successful image proof bound to manifest + all seven test/probe/tool inputs. Only business-worker may be rebuilt; API config/image remains identical. Old module absence is checked by lstat and FileNotFoundError only; permission/read errors and nonregular files fail. Rollback image bfde must actually lack the new module.
- Unknown guard exit/timeout/cleanup/wait stays UNKNOWN, with no automatic concurrent rollback. Only settled successful guard plus failed postcondition enters guarded rollback. Existing lock, schema/health, two zero-PROCESSING samples, previous-log hardlinks and unrelated-container checks remain. Two samples are **not** an atomic drain or exactly-once proof.
- `validate_default_runtime.py`: named UUID-owned, network-none, read-only, cap-drop/no-new-privileges, bounded-memory/CPU temporary containers. No PYTHONPATH/product mounts or live credentials. Tests include actual normal-import main() assembly + true internal receipt/renewal SQL, active-handler lifecycle, generation fencing and whole-process-pause limit. Installed and source Consumer plus main/worker/new module hashes are asserted. The historical source-only Consumer mismatch cannot pass.
- Container validation has 90s execution/15s cleanup bounds and records timeout/failure instead of success. Cleanup targets only its own UUID container. Receipt is image/manifest/input-bound before a later deploy can consume it.

## Local verification

- `absence-red.log`: old v2 behavior, 1 FAIL/1 PASS/1 preimplementation SKIP, exit1. Rollback cannot verify a deliberately missing new module.
- `absence-green.log`: new helper, 3 PASS, exit0.
- `local-boundaries.log`: 15 PASS, exit0, no Docker/SSH/production mutation. Actual selected script functions and actual digest snippets against synthetic temporary files. Covers five destinations, ABSENT versus permission/read/nonregular errors, isolated probe timeout/owned cleanup and evidence drift.
- `unknown-boundaries.json`: inherited 11 UNKNOWN/rollback/read-only DB timeout boundaries PASS, exit0, fixed deploy script SHA. Actual AST-selected bodies, inert subprocess/signals. No production switch.

Logs are normalized only for trailing whitespace/line endings for Git; semantic results and exit codes are retained. Full source author and independent reviews remain separate. No production DB/user content, financial writes, schema, historical DEAD replay or actual runtime switch is performed by these local tests.

## Actual immutable-image proof

- Candidate `sha256:abda33f8fe5bb4abca45464a5d300fff8981a8b68908be1b64f6e3ee0d8a0e7f`, network-none overlay of rollback bfde. `prepare-result.txt` exit0 and `services-manifest.json` bind image, all five paths and resolved private Compose hashes. API candidate/rollback image/config is identical; worker differs only by image. No API or worker service was recreated.
- `payload-transfer.json` binds frozen Git bundle `a99c26e1f72d95276d53eeae31306784e954af22827769825b97c3d76f1b8b45`. `stage_and_prepare.py` verifies its exact 14 paths and SHA, stages only this new release directory, reuses the existing immutable pytest-tool archive after SHA verification, and calls prepare only. Permanent guard/probe are not replaced.
- `default-runtime-receipt.json`: actual default cwd/import paths and five source hashes PASS; image pytest **70 PASS / 1 explicit PG-not-configured SKIP**, 2.07s, exit0. Both owned-container cleanups exit0. The actual-main fixture executes the real registered internal receipt and independent renewal SQL in synthetic SQLite; external/maintenance I/O remains isolated. The image PG SKIP does not replace the separate source/native-PG evidence.
- `protocol-check-output.txt`: candidate and rollback API a935 (same image, checked once by guard deduplication) and distinct worker abda/bfde each passed their nine role-specific protocol assertions. Check operation only; no deploy/rollback invocation.
- `candidate-checks-receipt.json` and `candidate-checks-result.txt`: checks 10:03:07.104590Z–10:03:26.101554Z (19.0s), default-runtime exit0, protocol exit0. Full `docker ps -a` **60** name/ID pairs before and after are exactly identical; added/removed/changed arrays empty. `running-containers-after.json` separately records current **35 running** containers, set SHA `70a7e0f4c4d79fac266d8b5c4be8565abd321d17b7ec79136f96cad1cfd693f5`. Do not mislabel all-container count60 as running count35. Worker remains db300/bfde. Root was notified immediately that no owned probe container remains and publication checks can proceed.
- `configuration-proof.json`, 10:07:12Z, read-only: actual frozen private API candidate/rollback is fully identical, worker differs only by its image; current API/worker IDs and images are still unchanged/healthy and permanent guard/probe SHAs match. No env/config values were emitted. `verify_evidence.py` binds downloaded receipts to exact frozen Git scripts/payloads and generates `deployment-input-identities.json`.
- Private inspect/env/Compose stayed only on server; only non-sensitive manifests/proof receipts were downloaded. New release files and candidate image were created, but no production data, service configuration, guard/probe or running service was changed.

## Evidence byte identities

Independent review found that the first `deployment-input-identities.json` at `2760bc102650fe92da5777e3b769ee756cee6e6d` mixed checkout CRLF hashes with Git LF hashes for ten files. `identity-byte-red.json` preserves the exact ten mismatches (audit exit1). No runtime receipt content or deployment core script changed to repair this documentation identity gap. `verify_evidence.py` now builds `files` from already-staged Git blobs; stage artifact changes before invoking it, then stage the generated identity file. `audit_identity_bytes.py <commit>` verifies that map against exact committed bytes (omitting the argument audits the index). `identity-byte-green.json` records exit0 after repair.

The separate `checkout_raw_files` map is an observation of this author's local bytes and is not portable across checkouts or `autocrlf` settings. Runtime receipt input hashes continue to describe actual immutable-image/container input bytes; they are not recalculated from normalized evidence logs or the checkout map. The manifest excludes its own identity file to avoid a self-hash cycle.

## Next step and rollback boundary

Independent SPEC/domain then QUALITY/security review of frozen scripts plus image evidence. Do not execute deploy during this preparation task. A later release must preserve approved source and current live topology; unrelated client/backend updates are not permission to transplant whole unverified files. Refresh the live baseline after Android publication; a changed baseline requires new freeze/proof, not reuse of an old PASS marker.
