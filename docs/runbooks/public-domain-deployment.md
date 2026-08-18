# Public-domain gateway deployment

This runbook deploys the approved `liuhetong888.com` gateway without changing
the existing Matrix `server_name` or identifiers.

## Required operator inputs

- Authorized shell or deployment-agent access to `207.56.8.8`.
- A trusted certificate whose SAN covers `liuhetong888.com`,
  `www.liuhetong888.com`, and `admin.liuhetong888.com`.
- The server-side production `.env` and Secret Manager values.
- A backup location outside the live Compose directories.

Never copy certificates, private keys, `.env`, access tokens, passwords, or
database dumps into Git.

## Production public values

Set these values in the server deployment environment:

```text
PUBLIC_HOSTNAME=liuhetong888.com
WWW_PUBLIC_HOSTNAME=www.liuhetong888.com
ADMIN_PUBLIC_HOSTNAME=admin.liuhetong888.com
SYNAPSE_PUBLIC_BASEURL=https://liuhetong888.com/
BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL=https://liuhetong888.com/
BUSINESS_AVATAR_PUBLIC_BASE_URL=https://liuhetong888.com
EMAIL_VERIFICATION_PUBLIC_BASE_URL=https://liuhetong888.com
```

Keep `MATRIX_SERVER_NAME`, `BUSINESS_MATRIX_SERVER_NAME`, internal Synapse URL,
database URLs, and Redis URLs unchanged.

## Backup

Before deployment, record the current image digests and back up the active
Nginx configuration, production environment, PostgreSQL data, Synapse data,
signing key, and encrypted media. Restrict backup permissions to the service
operator. Do not print secret files into CI logs.

## Render the gateway

Render `infra/nginx/nginx.conf` with `scripts/lib/TemplateTools.psm1` in a
secured deployment workspace:

```powershell
Import-Module ./scripts/lib/TemplateTools.psm1 -Force
Write-RenderedTemplate `
  -TemplatePath ./infra/nginx/nginx.conf `
  -DestinationPath ./out/nginx.conf `
  -Variables @{
    PUBLIC_HOSTNAME = 'liuhetong888.com'
    WWW_PUBLIC_HOSTNAME = 'www.liuhetong888.com'
    ADMIN_PUBLIC_HOSTNAME = 'admin.liuhetong888.com'
    SYNAPSE_PUBLIC_BASEURL = 'https://liuhetong888.com'
  }
```

Inspect the rendered file and confirm that no `{{...}}` token remains.

## Validate and activate

On the authorized server:

```sh
nginx -t -c /path/to/rendered/nginx.conf
docker compose config --quiet
docker compose up -d --no-deps business-api synapse element-web
nginx -s reload
```

Use the deployment platform's equivalent rolling/reload commands when Nginx
runs in a container. Do not stop PostgreSQL or delete/recreate data volumes.

After activation, run from a network outside the server:

```powershell
pwsh -NoProfile -File scripts/verify_public_domains.ps1 `
  -RootDomain liuhetong888.com `
  -WwwDomain www.liuhetong888.com `
  -AdminDomain admin.liuhetong888.com
```

The command must pass before publishing the domain-configured mobile build.

## Rollback

If TLS, health, Matrix discovery, login, message sync, or media access fails:

1. Restore the previous Nginx configuration and reload Nginx.
2. Restore the previous public URL environment values and roll back only the
   affected application containers.
3. Keep existing data volumes and Matrix signing keys mounted.
4. Re-run the old gateway health checks and record the failed deployment.

Never roll back by disabling certificate checks, allowing cleartext HTTP,
exposing `/_synapse/admin`, or changing Matrix `server_name`.
