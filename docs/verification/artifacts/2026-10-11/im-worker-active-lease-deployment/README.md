# R9b-2 deployment preparation

Status: scripts and local fault boundaries frozen for independent review; candidate build and image proof to follow. **No production worker switch has been run.** A later cutover requires Android publication and root's renewed live drift/authorization check. No product source changed in this directory's commit.

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

## Next step and rollback boundary

Independent SPEC/domain then QUALITY/security review, build exact candidate and run actual-image default-runtime plus candidate/rollback dual-role protocol gates. Attach immutable image and proof receipts before claiming readiness. Do not execute deploy during this preparation task. A later release must preserve approved source and current live topology; unrelated client/backend updates are not permission to transplant whole unverified files.
