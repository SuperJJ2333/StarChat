# StarChat Foundation Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair unsafe configuration generation, establish repository/Agent rules and repeatable tests, lock infrastructure versions, and restrict the existing Matrix Bot to explicitly authorized notification rooms.

**Architecture:** Extract template rendering into a pure PowerShell module with strict unresolved-token checks. Add repository policy tests and a pure Python room-access policy before wiring it into the Matrix client. Keep Phase 0 independent of Docker runtime so it is verifiable while Docker Desktop is unavailable.

**Tech Stack:** PowerShell 7, Python 3.12, pytest, FastAPI, matrix-nio, Docker Compose.

## Global Constraints

- Preserve E2EE; the Bot must not auto-join or receive keys for ordinary rooms.
- Generated configs must contain no unresolved `{{NAME}}` tokens or extra wrapper braces.
- Production images may not use `latest`.
- Tests must run with UTF-8 input/output and Python UTF-8 mode on Windows.
- Do not edit generated runtime data by hand; regenerate it from templates.
- This workspace has no `.git` directory. Do not run `git init`; for each task write a verification checkpoint under `docs/verification/phase-0/` instead of creating a commit.

---

### Task 1: Repository and Agent Governance

**Files:**
- Create: `tests/repository/Test-RepositoryPolicy.ps1`
- Create: `AGENTS.md`
- Create: `infra/AGENTS.md`
- Create: `services/matrix-bot/AGENTS.md`
- Modify: `.gitignore`
- Create: `docs/verification/phase-0/task-1-governance.md`

**Interfaces:**
- Consumes: Approved design spec at `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`.
- Produces: Scoped coding rules inherited by all later implementation work and an executable repository policy test.

- [ ] **Step 1: Write the failing repository policy test**

```powershell
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$gitignore = Get-Content (Join-Path $root '.gitignore') -Raw -Encoding UTF8
Assert-True ($gitignore -match '(?m)^\.superpowers/$') '.superpowers/ must be ignored'
Assert-True (Test-Path (Join-Path $root 'AGENTS.md')) 'root AGENTS.md is required'
Assert-True (Test-Path (Join-Path $root 'infra\AGENTS.md')) 'infra AGENTS.md is required'
Assert-True (Test-Path (Join-Path $root 'services\matrix-bot\AGENTS.md')) 'matrix-bot AGENTS.md is required'
Write-Output 'Repository policy: PASS'
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```powershell
pwsh -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1
```

Expected: FAIL because `.superpowers/` and the scoped `AGENTS.md` files do not exist.

- [ ] **Step 3: Add the approved governance files**

Root `AGENTS.md` must contain the global invariants, UTF-8 PowerShell convention, test commands, file ownership rule, no-secrets rule, no-float/no-direct-balance rule, E2EE boundary, migration rules, and completion evidence requirements. Scoped files must add infrastructure and Bot restrictions without weakening root rules.

Append to `.gitignore`:

```gitignore
.superpowers/
.venv/
coverage.xml
htmlcov/
docs/verification/**/*.tmp
```

- [ ] **Step 4: Run the repository policy test**

Expected: `Repository policy: PASS`.

- [ ] **Step 5: Record the checkpoint**

Create `docs/verification/phase-0/task-1-governance.md` with the command, timestamp, exit code, and list of created/modified files.

### Task 2: Strict PowerShell Template Rendering

**Files:**
- Create: `scripts/lib/TemplateTools.psm1`
- Create: `tests/powershell/Test-TemplateTools.ps1`
- Modify: `scripts/init_matrix.ps1:1-216`
- Create: `docs/verification/phase-0/task-2-template-rendering.md`

**Interfaces:**
- Consumes: A template string containing exact `{{UPPER_SNAKE_CASE}}` tokens and a hashtable of values.
- Produces: `Expand-StrictTemplate -Content <string> -Variables <hashtable> -> string` and `Write-RenderedTemplate -TemplatePath -DestinationPath -Variables`.

- [ ] **Step 1: Write failing tests for exact replacement and unresolved tokens**

```powershell
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\scripts\lib\TemplateTools.psm1') -Force

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message`nExpected: $Expected`nActual: $Actual" }
}

$rendered = Expand-StrictTemplate `
    -Content 'server_name: "{{MATRIX_SERVER_NAME}}"' `
    -Variables @{ MATRIX_SERVER_NAME = 'matrix.localhost' }
Assert-Equal $rendered 'server_name: "matrix.localhost"' 'double-brace token replacement failed'

$json = Expand-StrictTemplate `
    -Content '{"base_url":"{{BASE_URL}}"}' `
    -Variables @{ BASE_URL = 'https://chat.example.test/' }
$null = $json | ConvertFrom-Json
Assert-Equal $json '{"base_url":"https://chat.example.test/"}' 'JSON rendering failed'

$threw = $false
try { Expand-StrictTemplate -Content '{{MISSING}}' -Variables @{} } catch { $threw = $true }
if (-not $threw) { throw 'unresolved tokens must fail' }
Write-Output 'TemplateTools: PASS'
```

- [ ] **Step 2: Run the test and verify import/function failure**

Run: `pwsh -NoProfile -File tests/powershell/Test-TemplateTools.ps1`  
Expected: FAIL because `TemplateTools.psm1` does not exist.

- [ ] **Step 3: Implement exact rendering**

```powershell
function Expand-StrictTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    foreach ($key in $Variables.Keys) {
        $token = '{{' + [string]$key + '}}'
        $Content = $Content.Replace($token, [string]$Variables[$key])
    }

    $unresolved = [regex]::Matches($Content, '\{\{[A-Z][A-Z0-9_]*\}\}')
    if ($unresolved.Count -gt 0) {
        $names = $unresolved.Value | Sort-Object -Unique
        throw "Unresolved template tokens: $($names -join ', ')"
    }

    return $Content
}
```

`Write-RenderedTemplate` must call this function and write UTF-8 without BOM. `init_matrix.ps1` must import the module and remove the faulty local `Render-Template` implementation.

- [ ] **Step 4: Add `-RenderOnly` to initialization**

Extend the parameter block to:

```powershell
param(
    [switch]$StartAll,
    [switch]$RenderOnly
)
```

After rendering Synapse/Element configuration, return before Docker operations when `RenderOnly` is set. This makes rendering independently testable.

- [ ] **Step 5: Run unit and render-only tests**

Run:

```powershell
pwsh -NoProfile -File tests/powershell/Test-TemplateTools.ps1
pwsh -NoProfile -File scripts/init_matrix.ps1 -RenderOnly
```

Expected: unit test PASS; generated `server_name`, `public_baseurl`, and Element `base_url` contain no wrapper braces.

- [ ] **Step 6: Record the checkpoint**

Record commands, exit codes, and exact rendered key/value assertions in `docs/verification/phase-0/task-2-template-rendering.md` without copying secrets.

### Task 3: Configuration and Image Policy

**Files:**
- Create: `tests/repository/Test-DeploymentPolicy.ps1`
- Modify: `docker-compose.yml:1-72`
- Modify: `.env.example:1-6`
- Modify: `services/matrix-bot/Dockerfile:1`
- Create: `docs/verification/phase-0/task-3-deployment-policy.md`

**Interfaces:**
- Consumes: Explicit image references from `.env`.
- Produces: Compose configuration that has no `latest` fallback and fails fast if a required image is absent.

- [ ] **Step 1: Write the failing deployment policy test**

```powershell
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$files = @(
    Join-Path $root 'docker-compose.yml'
    Join-Path $root '.env.example'
    Join-Path $root 'services\matrix-bot\Dockerfile'
)
foreach ($file in $files) {
    $content = Get-Content $file -Raw -Encoding UTF8
    if ($content -match '(?i)(?:^|[:=])latest(?:\s|$|\})') {
        throw "floating latest reference found in $file"
    }
}
docker compose --env-file .env.example config --quiet
if ($LASTEXITCODE -ne 0) { throw 'docker compose config failed' }
Write-Output 'Deployment policy: PASS'
```

- [ ] **Step 2: Run the test and verify `latest` failure**

Expected: FAIL on Synapse and Element image defaults.

- [ ] **Step 3: Remove floating defaults and pin development references**

Use these explicit Phase 0 compatibility baseline tags:

```dotenv
POSTGRES_IMAGE=postgres:16.9-alpine
SYNAPSE_IMAGE=matrixdotorg/synapse:v1.132.0
ELEMENT_WEB_IMAGE=vectorim/element-web:v1.11.100
PYTHON_IMAGE=python:3.12.11-slim
```

Compose must use `${POSTGRES_IMAGE:?POSTGRES_IMAGE is required}` style expressions. The Bot Dockerfile must declare `ARG PYTHON_IMAGE=python:3.12.11-slim` and `FROM ${PYTHON_IMAGE}`.

- [ ] **Step 4: Validate tags and Compose structure**

Run the policy test. If registry access is available, also run:

```powershell
docker buildx imagetools inspect postgres:16.9-alpine
docker buildx imagetools inspect matrixdotorg/synapse:v1.132.0
docker buildx imagetools inspect vectorim/element-web:v1.11.100
docker buildx imagetools inspect python:3.12.11-slim
```

Do not replace a missing tag by `latest`; select an explicit existing release and update the test evidence and compatibility baseline together.

- [ ] **Step 5: Record the checkpoint**

Write `docs/verification/phase-0/task-3-deployment-policy.md` with Compose validation and manifest results. If registry access is unavailable, record that manifest verification is blocked while keeping the static policy result separate.

### Task 4: Notification Bot Room Access Policy

**Files:**
- Create: `services/matrix-bot/app/room_policy.py`
- Create: `tests/matrix_bot/test_room_policy.py`
- Modify: `services/matrix-bot/app/settings.py:25-61`
- Modify: `services/matrix-bot/app/matrix_client.py:17-148`
- Modify: `services/matrix-bot/app/api.py:41-67`
- Modify: `docker-compose.yml:48-68`
- Modify: `.env.example`
- Create: `docs/verification/phase-0/task-4-room-policy.md`

**Interfaces:**
- Consumes: `MATRIX_ALLOWED_ROOM_TARGETS_JSON`, a JSON list of authorized room IDs/aliases.
- Produces: `RoomAccessPolicy.is_allowed(target: str) -> bool`, `RoomTargetNotAllowed`, send-time enforcement, and invite refusal.

- [ ] **Step 1: Write failing pure policy tests**

```python
import pytest

from app.room_policy import RoomAccessPolicy, RoomTargetNotAllowed


def test_allowed_room_can_be_used() -> None:
    policy = RoomAccessPolicy({"!system:example.test", "#notice:example.test"})
    policy.require_allowed("!system:example.test")


def test_unknown_room_is_rejected() -> None:
    policy = RoomAccessPolicy({"!system:example.test"})
    with pytest.raises(RoomTargetNotAllowed):
        policy.require_allowed("!private:example.test")


def test_empty_allowlist_denies_every_room() -> None:
    policy = RoomAccessPolicy(set())
    assert not policy.is_allowed("!any:example.test")
```

- [ ] **Step 2: Run tests and verify module import failure**

Run:

```powershell
$env:PYTHONPATH='services/matrix-bot'
python -m pytest tests/matrix_bot/test_room_policy.py -q
```

Expected: FAIL because `app.room_policy` does not exist.

- [ ] **Step 3: Implement the pure policy**

```python
class RoomTargetNotAllowed(ValueError):
    pass


class RoomAccessPolicy:
    def __init__(self, allowed_targets: set[str]) -> None:
        self._allowed_targets = frozenset(allowed_targets)

    def is_allowed(self, target: str) -> bool:
        return target in self._allowed_targets

    def require_allowed(self, target: str) -> None:
        if not self.is_allowed(target):
            raise RoomTargetNotAllowed(f"Matrix room target is not authorized: {target}")
```

- [ ] **Step 4: Wire settings, sends, invites, and API errors**

Add a parsed `allowed_room_targets` setting. `send_message()` must reject before resolve/join. `_on_invite()` must join only if `room.room_id` is authorized and otherwise log a metadata-only warning. API publishing must translate `RoomTargetNotAllowed` to HTTP 403 with stable detail `MATRIX_ROOM_NOT_ALLOWED`.

- [ ] **Step 5: Run room policy and Python parse tests**

Expected: all room policy tests PASS and all nine existing Python modules plus the new module parse successfully.

- [ ] **Step 6: Record the checkpoint**

Record test output and the deny-by-default behavior in `docs/verification/phase-0/task-4-room-policy.md`.

### Task 5: Unified Verification Command

**Files:**
- Create: `services/matrix-bot/requirements-dev.txt`
- Create: `scripts/verify.ps1`
- Modify: `README.md`
- Create: `docs/verification/phase-0/task-5-verification.md`

**Interfaces:**
- Consumes: Repository source and local Python/PowerShell tooling.
- Produces: One command that verifies repository policies, template behavior, Python parsing/tests, and Compose rendering.

- [ ] **Step 1: Add development test dependencies**

```text
pytest>=8.3,<9.0
pytest-asyncio>=0.24,<1.0
```

- [ ] **Step 2: Implement `scripts/verify.ps1`**

The script must set UTF-8 console/Python variables, stop on error, then run in this exact order:

```powershell
pwsh -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1
pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1
pwsh -NoProfile -File tests/powershell/Test-TemplateTools.ps1
$env:PYTHONPATH = 'services/matrix-bot'
python -m pytest tests/matrix_bot -q
python -c "import ast,pathlib; [ast.parse(p.read_text(encoding='utf-8'), filename=str(p)) for p in pathlib.Path('services/matrix-bot/app').glob('*.py')]"
docker compose --env-file .env.example config --quiet
```

Each failed native command must cause a non-zero script exit.

- [ ] **Step 3: Update README development instructions**

Document setup, render-only configuration, allowlisted notification rooms, verification, Docker-unavailable behavior, and the link to the approved design and master roadmap.

- [ ] **Step 4: Run the complete verification command**

Run: `pwsh -NoProfile -File scripts/verify.ps1`  
Expected: all static and unit checks PASS. Docker engine is not required for `docker compose config`.

- [ ] **Step 5: Record the final Phase 0 checkpoint**

Write `docs/verification/phase-0/task-5-verification.md` containing every command, exit code, pass count, any registry-only limitation, and the remaining Phase 1 entry criteria.

## Phase 0 Completion Gate

Phase 0 is complete only when:

1. `scripts/verify.ps1` exits 0 from a fresh PowerShell 7 session.
2. Rendered Synapse and Element values contain no unmatched wrapper braces.
3. Repository and deployment policy tests pass.
4. The notification Bot denies every room not present in its allowlist.
5. No runtime data, generated configuration, `.env`, recovery key, signing key, or production credential was added to source-controlled paths.
