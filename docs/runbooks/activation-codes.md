# Registration Activation Codes

The production business API owns invitation-code hashing, use limits, and expiry. Generate a code from the server's application directory with the running API container:

```powershell
ssh -p 23421 root@207.56.8.8
docker compose exec business-api python -m app.cli.generate_invitation --created-by server-admin
```

The command prints the plaintext code once, its UTC expiry, and `max_uses=1`. Share the code through a private channel and do not put it in logs, tickets, or source control. The default expiry is 30 days from command execution.

To validate a code without consuming it, call the public validation endpoint from the server or an authorized admin workstation:

```powershell
$body = @{ invitation_code = '<PASTE_CODE>' } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8082/api/v1/invitations/validate' -ContentType 'application/json' -Body $body
```

Expected response before use is `{ "valid": true }`. A successful registration atomically consumes the code; subsequent validation returns `{ "valid": false }`.
