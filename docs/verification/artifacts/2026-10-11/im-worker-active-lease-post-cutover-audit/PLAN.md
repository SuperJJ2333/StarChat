# Independent read-only post-cutover audit

Status: prepared locally only; no remote command, container operation, production query or audit has been executed in this task. Owner: backend_review. Wait for root's settled worker cutover notice, full new worker container ID, and exact `deployment.json.started_utc`. This is not authorization to deploy or recover services.

Use the existing `starchat-admin-production` skill and `docs/runbooks/admin-production-workflow.md`. Source c3dd, deployment preparation final41e878, independent preparation review277510 remain the reviewed inputs. No product files, root worktree, shared task record or existing receipts are edited here.

## Fixed scope

1. Read the prepared release's public deployment receipt. Require PASS, root-notified new worker ID, candidate `sha256:abda33f8fe5bb4abca45464a5d300fff8981a8b68908be1b64f6e3ee0d8a0e7f`, schema0095 and the exact cutover start time. If not settled, stop before runtime queries; report NOT_VERIFIED, with no retry/deploy/rollback.
2. Inspect current worker and API, but output only image/ID, running/status/health, restart count, OOM flag and start time. Worker must be candidate/new ID/healthy/restart0/noOOM. API remains ID87c627… and imagea935…/healthy/restart0/noOOM.
3. In the existing worker, use one bounded `docker exec python -B` to lstat/read/hash exactly five reviewed paths. Both installed Consumer and source Consumer must match new8306…, mainf320…, workerb59f…, newlease37ae…. No worker main import, test execution, handler call or temporary container.
4. Compare current full container name/ID table to the private frozen before table, excluding only business-worker; print counts and drift names, not the private table. Record running35 versus all60 distinctly. A drift requires explanation/fresh scope review, not automatic rollback.
5. Read/hash permanent guard46d98… and probe2a6de… without executing either. Query only `alembic_version` through existing API with a new connection, transaction READ ONLY, connect_timeout3s, statement_timeout5s and docker exec deadline12s. No Outbox payload, financial row, token or user data query.
6. HTTPS GET `/api/v1/health/ready` with normal certificate validation, timeout10s; retain only status code. Health alone is not proof of deployed renewal/protocol correctness.
7. Read worker logs since the exact settled cutover start, capped by `--tail 2000` and12s. Keep raw text only in process memory; output fixed counts (traceback/error/warning/lease-state/database-timeout categories) and sample scope. Categories overlap and are heuristic; classify flagged counts with root before concluding defect. Zero counts in this bounded sample are not proof of all-time absence. No raw log lines, event/user IDs, messages, DSNs, tokens or exception strings are emitted.

`audit_readonly.py` embeds the exact accepted identities. Every external command is read-only (`docker inspect`, `ps`, `exec` for fixed reads/SELECT, `logs`). It never calls Docker run/compose/restart/remove/build, guard check/deploy/rollback, SQL DML, uploads, writes remote files or follows logs. Python `-B` prevents bytecode writes in existing containers. Subprocess/HTTP failures emit exception class only and return NOT_VERIFIED; the audit performs no recovery.

## Command to use only after root's completion notice

Use PowerShell7 UTF-8 and the repository jumper wrapper. Fill the two variables from root's actual settled deployment receipt; do not invent them. Base64 carries exact local frozen script bytes without uploading/writing a remote file. The only output file below is local and must live in this owned verification directory.

```powershell
$taskEncoding=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskEncoding
[Console]::OutputEncoding=$taskEncoding
$OutputEncoding=$taskEncoding
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$env:PYTHONDONTWRITEBYTECODE='1'
# $taskWorkerId and $taskStartedUtc come from root's completed cutover notice.
if ($taskWorkerId -notmatch '^[0-9a-f]{64}$') { throw 'Missing exact settled worker ID' }
if ($taskStartedUtc -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') { throw 'Missing exact cutover UTC' }
$taskAuditPath=Join-Path $PWD 'docs/verification/artifacts/2026-10-11/im-worker-active-lease-post-cutover-audit/audit_readonly.py'
$taskScript64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($taskAuditPath))
$taskArgJson=ConvertTo-Json -Compress -InputObject @('audit_readonly.py','--expected-worker-id',$taskWorkerId,'--cutover-started-utc',$taskStartedUtc)
$taskArgs64=[Convert]::ToBase64String($taskEncoding.GetBytes($taskArgJson))
$taskPython="import base64,json,sys;sys.argv=json.loads(base64.b64decode('$taskArgs64'));exec(compile(base64.b64decode('$taskScript64'),'readonly-post-cutover-audit','exec'))"
$taskRemote='python3 -B -c "' + $taskPython + '"'
& pwsh.exe -NoProfile -File scripts/starchat-server.ps1 -Action Command -RemoteCommand $taskRemote
# Preserve wrapper exit code and only sanitized JSON output locally after execution.
```

Before actual use, freeze/hash this script and record the root-provided identities plus the UTC observation interval. This plan does not create a background watch or promise a future automatic action. Root must send the completion notice. Any new 35-container baseline drift is reported, never corrected here. A healthy snapshot cannot establish that an actual production handler exceeded five minutes or prove external exactly-once; those are separate isolated-source evidence and existing idempotency boundaries.
