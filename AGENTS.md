# StarChat Agent Rules

## Deployment access

- SSH target: `root@207.56.8.8`
- SSH port: `23421`
- Authentication: passwordless SSH configured locally; private keys and tokens are not stored in this repository.

These rules apply to the entire repository. A deeper `AGENTS.md` may add stricter rules but may not weaken this file.

## Required context

- Android APK packaging must follow `docs/runbooks/android-apk-rebuild.md` (user-confirmed on 2026-09-05): source build, conventional DEX/resource/manifest rebuild, alignment, stable user-tested signing identity, and artifact verification. A raw Flutter/Gradle APK is an intermediate, not the final user delivery. Do not rotate the key per build, silently revert to an older signer, or copy arbitrary padding/manifest changes from third-party tools. This replaces the earlier source-only/no-rebuild preference; no packer or Dart/R8 obfuscation is requested.

- Read `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md` before changing product behavior.
- Execute work from an approved plan under `docs/superpowers/plans/`.
- Record non-Git verification evidence under `docs/verification/` while this workspace has no `.git` directory.
- Temporary verification artifacts must be created only under `docs/verification/artifacts/<YYYY-MM-DD>/` (or another named subfolder below `docs/verification/`); the repository root must never contain verification artifacts such as `MODIFIED_FILE`, `DIFF_FILE`, `VERIFICATION.txt`, or `ROLLBACK.sh`.

## Shell and encoding

- Run terminal commands through PowerShell 7 (`pwsh.exe`).
- At the beginning of every PowerShell session, set console input, output, and pipeline encoding to UTF-8 without BOM.
- Set `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` before invoking Python.
- Use `-LiteralPath` and explicit UTF-8 encoding when reading or writing text files.

## Architectural invariants

- Matrix is the encrypted communications domain; business APIs are authoritative for identity, support, ledger, red packets, and wallets.
- Never derive or mutate financial state from Matrix messages, bot callbacks, push notifications, or client display state.
- Never give the server user recovery keys, room keys, message plaintext, plaintext attachments, or decrypted call media.
- CAIBI（展示名：彩币） uses two decimal places and USDT uses six. Use `Decimal`/`NUMERIC`; never use binary floating point for assets.
- Ledger transactions and entries are append-only and balanced per asset. Correct errors with linked reversal transactions.
- CAIBI and USDT are isolated. Do not add conversion, USDT P2P transfer, or USDT red packets.
- Every financial write requires an idempotency key, a stable reason code, actor identity, audit record, and transactional Outbox event.

## Development workflow

1. Claim one bounded task and declare the files it owns.
2. Write a failing test and verify that it fails for the intended missing behavior.
3. Implement the minimum change required to pass.
4. Run focused tests, then `pwsh -NoProfile -File scripts/verify.ps1` when that script exists.
5. Update OpenAPI, migrations, configuration, runbooks, and verification evidence with the code they describe.
6. Run a specification-compliance review before a quality/security review.

Agents must not edit the same file concurrently. Cross-module behavior must use public application interfaces; direct cross-module table writes are prohibited.

## Security and repository hygiene

- Never commit `.env`, runtime databases, generated homeserver data, signing keys, recovery keys, access tokens, real wallet addresses, custody credentials, or unredacted sensitive logs.
- Do not log message bodies, attachment contents, passwords, tokens, full wallet addresses, or provider secrets.
- Production dependencies and container images must use explicit versions or digests; `latest` is forbidden.
- Do not silently weaken E2EE, RBAC, TOTP, approval, idempotency, reconciliation, or audit checks.
- Do not run destructive migrations. Use expand-migrate-contract and prove rollback/restore behavior.

## Protected changes

An approved ADR and both domain and Quality/Security review are required for ledger schema/formula changes, red-packet allocation, wallet state transitions, custody contracts, E2EE/key recovery, authentication/RBAC/TOTP, destructive migrations, and breaking OpenAPI changes.

## Definition of done

- The new behavior has test-first red/green evidence.
- Formatting, lint, type checks, unit tests, integration tests, and relevant end-to-end tests pass.
- Financial invariants, E2EE boundaries, idempotency, and permission checks have dedicated assertions.
- Documentation and generated clients match the implemented contract.
- No placeholders, hard-coded secrets, temporary bypasses, ignored warnings, or unexplained failures remain.

