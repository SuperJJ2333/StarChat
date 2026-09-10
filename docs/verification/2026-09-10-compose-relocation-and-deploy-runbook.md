# Compose overlay relocation and deploy runbook

Date: 2026-09-10. Follow-up to the 0.3.69/0.3.73 release deployments; requested by the user: "编写deploy文档避免类似的问题再次发生，并且清理根目录下的yml文档…请勿错误删除，而是归档".

## What was found before touching anything

All six non-core yml files in the repository root are live, not stale:

- `docker-compose.yml`, `docker-compose.production.yml`: base and production compose; `tests/repository/Test-DeploymentPolicy.ps1` hard-codes the production file at the root (`Join-Path $root 'docker-compose.production.yml'`), so both stay at the root.
- `analysis_options.yaml`: Dart analyzer configuration, not deployment; untouched.
- The five overlays (`docker-compose.tron-watch.yml`, `docker-compose.wallet-chain.yml`, `docker-compose.wallet-manual.yml`, `docker-compose.wallet-release.yml`, `docker-compose.wallet-rollback.yml`) are each referenced by `tests/infra/test_*.py` (which run inside `scripts/verify.ps1`) and by runbooks. Archiving or deleting them would have broken verification. They were also all untracked in git, so plain `mv` was used.

## Change

1. Relocated the five overlays to `infra/compose/` (a proper home rather than an archive, because they are active). Root now holds exactly `analysis_options.yaml`, `docker-compose.yml`, `docker-compose.production.yml`.
2. Updated every active reference: 4 test files (9 path expressions) and 3 runbooks (6 mentions). The historical design spec `docs/superpowers/specs/2026-09-08-wallet-diagnostic-logging-design.md` intentionally still names the old root paths — it is a dated design record and was not rewritten.
3. New runbook `docs/runbooks/app-release-deployment.md` capturing the deployment lessons from the 0.3.69/0.3.73 releases: artifact gates, the two SSH routes (default proxy route and the `ssh -J jumper` fallback) with diagnosis order, the resumable chunked upload procedure with SHA256 gates and the no-cleanup-during-upload rule, iOS OTA manifest/page handling, the app-update settings publish pattern (platform-aware `app_apk_url`, VARCHAR(255) notes limit, inspect/apply/rollback), the verification checklist, and rollback paths.

## Verification

- `py -3.12 -m pytest tests/infra -q` → **102 passed** after the relocation (this suite runs in `scripts/verify.ps1`).
- Repository-wide reference scan for the five moved filenames: the only remaining old-path mention is the preserved historical spec; all active code and runbooks point at `infra/compose/`.
- Root listing: only `analysis_options.yaml`, `docker-compose.yml`, `docker-compose.production.yml` remain.

Not claimed: a full `scripts/verify.ps1` pass was not run for this documentation/hygiene change; the affected suite (tests/infra) was run directly and passed.
