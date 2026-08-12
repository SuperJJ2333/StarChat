# Phase 0 Task 3 Verification — Deployment Policy

**Verified:** 2026-08-12 (Asia/Hong_Kong)

## Red evidence

`pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1` exited `1` with:

```text
floating latest reference found in ...\docker-compose.yml
```

## Green evidence

After removing floating fallbacks and pinning explicit baseline tags, the same command exited `0` with:

```text
Deployment policy: PASS
```

`docker compose config --quiet` also exited `0` using the local ignored `.env`.

## Compatibility baseline

```text
postgres:16.9-alpine
matrixdotorg/synapse:v1.132.0
vectorim/element-web:v1.11.100
python:3.12.11-slim
```

Registry manifest verification was attempted for all four references. Every request reached Docker Hub but ended in a TLS handshake timeout, so remote existence/architecture evidence remains blocked by registry connectivity. Static policy and Compose rendering passed; production release remains gated on successful manifest and integration verification and must not fall back to `latest`.

## Files

- Created `tests/repository/Test-DeploymentPolicy.ps1`
- Updated `docker-compose.yml`
- Updated `.env.example`
- Updated ignored local `.env` image references without exposing its secrets
- Updated `services/matrix-bot/Dockerfile`
