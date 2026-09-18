# Registration Activation Codes

**Status: Current.** [Runbooks index](README.md) · [Approved server access](admin-production-workflow.md).

**owner:** 项目维护者；**last_verified:** 2026-09-10（文档状态与链接核对，不代表当前生产验收）。

The production business API owns invitation-code hashing, use limits, and expiry. Generate a code from the server's application directory with the running API container:

```powershell
ssh -J jumper -p 23421 root@207.56.8.8
```

Then run in the remote Linux shell:

```sh
cd /opt/starchat
docker compose exec -T business-api python -m app.cli.generate_invitation --created-by server-admin
```

The command prints the plaintext code once, its UTC expiry, and `max_uses=1`. Share the code through a private channel and do not put it in logs, tickets, or source control. The default expiry is 30 days from command execution.

To validate a code without consuming it, call the public validation endpoint from the server or an authorized admin workstation:

```powershell
$body = @{ invitation_code = '<PASTE_CODE>' } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8082/api/v1/invitations/validate' -ContentType 'application/json' -Body $body
```

Expected response before use is `{ "valid": true }`. A successful registration atomically consumes the code; subsequent validation returns `{ "valid": false }`.

## Consolidated note

The former `docs/ME.md` shorthand has been merged here (2026-09-10): `/opt/starchat` and non-interactive `exec -T` are preserved, and SSH uses the approved jumper. Original bytes are preserved in the [document archive](../verification/archives/2026-09-10-docs-cleanup/document-originals/ME.md). The old direct-SSH snippet in that archive is historical.
