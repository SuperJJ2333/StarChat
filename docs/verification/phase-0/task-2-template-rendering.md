# Phase 0 Task 2 Verification — Strict Template Rendering

**Verified:** 2026-08-12 (Asia/Hong_Kong)

## Red evidence

`pwsh -NoProfile -File tests/powershell/Test-TemplateTools.ps1` exited `1` because `scripts/lib/TemplateTools.psm1` did not exist.

## Green evidence

The same command exited `0` with:

```text
TemplateTools: PASS
```

Render-only command:

```powershell
pwsh -NoProfile -File scripts/init_matrix.ps1 -RenderOnly
```

exited `0`. Assertions verified:

```text
server_name: "matrix.localhost"
public_baseurl: "http://localhost:8008/"
signing_key_path: "/data/matrix.localhost.signing.key"
Element base_url=http://localhost:8008/
Element server_name=matrix.localhost
```

No unresolved double-brace token or erroneous wrapper-brace value remained in the generated Synapse/Element configuration.

## Files

- Created `scripts/lib/TemplateTools.psm1`
- Created `tests/powershell/Test-TemplateTools.ps1`
- Updated `scripts/init_matrix.ps1`
- Regenerated ignored runtime files under `data/synapse/` and `data/element/`

No secrets are reproduced in this evidence file.
