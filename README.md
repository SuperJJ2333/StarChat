# StarChat Matrix/Element Private Messaging Stack

This repository provides a private encrypted messaging stack based on Matrix Synapse, Element Web, and a custom Matrix Bot service. It is designed as an integration skeleton that can be connected to an existing business system through an internal webhook instead of rebuilding an IM protocol from scratch.

## Product Modernization Status

The repository is being upgraded from the original integration skeleton into the approved StarChat product. The authoritative design and delivery roadmap are:

- [`docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`](docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md)
- [`docs/superpowers/plans/2026-08-12-starchat-master-implementation-roadmap.md`](docs/superpowers/plans/2026-08-12-starchat-master-implementation-roadmap.md)

Phase 0 repairs configuration rendering, locks deployment inputs, establishes tests and Agent rules, and restricts the existing Bot to explicitly authorized notification rooms. Flutter, the business backend, POINT ledger/red packets, USDT custody integration, encrypted calls, and the React administration application are delivered by later phases and must not be inferred from the current skeleton.

The approved privacy boundary requires E2EE for messages, attachments, support rooms, and calls. The platform does not perform server-side message scanning. The existing Bot must not join ordinary private or group rooms.

## Architecture

- `postgres`: Synapse metadata storage.
- `synapse`: Matrix homeserver.
- `element-web`: Browser chat client.
- `matrix-bot`: FastAPI service for announcements, lottery notifications, auto-replies, and business event delivery.
- `infra/nginx/nginx.conf`: Production reverse proxy example.

## Project Layout

```text
.
|-- .env.example
|-- docker-compose.yml
|-- infra
|   |-- element
|   |   `-- config.json.template
|   |-- nginx
|   |   `-- nginx.conf
|   `-- synapse
|       |-- homeserver.yaml.template
|       |-- log.config
|       |-- register_admin.sh
|       `-- register_bot.sh
|-- scripts
|   `-- init_matrix.ps1
`-- services
    `-- matrix-bot
        |-- Dockerfile
        |-- requirements.txt
        `-- app
            |-- __init__.py
            |-- api.py
            |-- handlers.py
            |-- idempotency.py
            |-- main.py
            |-- matrix_client.py
            |-- models.py
            |-- router.py
            `-- settings.py
```

## Prerequisites

- Docker Desktop with Compose support
- PowerShell 7+ on Windows for the provided bootstrap script
- A domain name and HTTPS reverse proxy for production

## Environment Variables

Copy `.env.example` to `.env` and replace all placeholder secrets.

### Core infrastructure

| Variable | Description |
| --- | --- |
| `POSTGRES_DB` | Synapse PostgreSQL database name |
| `POSTGRES_USER` | PostgreSQL username |
| `POSTGRES_PASSWORD` | PostgreSQL password |
| `MATRIX_SERVER_NAME` | Matrix server name used in Matrix IDs, e.g. `chat.example.com` |
| `SYNAPSE_PUBLIC_BASEURL` | Client-facing Synapse base URL, must end with `/` |
| `SYNAPSE_INTERNAL_BASEURL` | Container-to-container Synapse URL, normally `http://synapse:8008/` |
| `ELEMENT_PUBLIC_URL` | Browser-facing Element URL |
| `PUBLIC_HOSTNAME` | Public hostname used by the sample Nginx config |

### Bootstrap accounts and secrets

| Variable | Description |
| --- | --- |
| `SYNAPSE_ADMIN_USERNAME` | Localpart for the first admin user |
| `SYNAPSE_ADMIN_PASSWORD` | Password for the first admin user |
| `SYNAPSE_BOT_USERNAME` | Localpart for the bot account |
| `SYNAPSE_BOT_PASSWORD` | Password for the bot account |
| `MATRIX_BOT_USER_ID` | Full bot Matrix user ID, e.g. `@matrixbot:chat.example.com` |
| `MATRIX_BOT_DEVICE_ID` | Device ID for bot E2EE sessions |
| `MATRIX_BOT_ACCESS_TOKEN` | Optional existing access token; leave blank to login by password |
| `SYNAPSE_REGISTRATION_SHARED_SECRET` | Secret used by `register_new_matrix_user` |
| `SYNAPSE_MACAROON_SECRET_KEY` | Synapse macaroon signing secret |
| `SYNAPSE_FORM_SECRET` | Synapse form secret |

### Matrix bot settings

| Variable | Description |
| --- | --- |
| `MATRIX_WEBHOOK_API_KEY` | Internal webhook API key for the business system |
| `MATRIX_DEFAULT_ROOM_ID` | Optional fallback room ID |
| `MATRIX_ROOM_ROUTING_JSON` | JSON object mapping `route_key` or `event:<event_type>` to a room ID or room alias |
| `MATRIX_ALLOWED_ROOM_TARGETS_JSON` | JSON list of the only room IDs/aliases the notification Bot may join or send to; empty denies all rooms |
| `MATRIX_AUTO_REPLY_RULES_JSON` | JSON array of auto-reply rules |
| `MATRIX_ADMIN_USERS_JSON` | JSON array of admin user IDs allowed to run privileged bot commands |
| `MATRIX_COMMAND_PREFIX` | Bot command prefix |
| `MATRIX_MESSAGE_DEDUP_TTL_SECONDS` | Idempotency retention window |
| `MATRIX_IDEMPOTENCY_DB_PATH` | SQLite file used to store webhook idempotency keys |
| `MATRIX_BOT_STORE_PATH` | matrix-nio crypto/device store path |
| `MATRIX_ALLOW_UNVERIFIED_DEVICES` | Ignore unverified devices when sending encrypted messages |

## Local Startup

### 1. Prepare environment

```powershell
Copy-Item .env.example .env
```

Edit `.env` and replace all `change-this-*` values.

Install development dependencies before running verification:

```powershell
python -m pip install -r services/matrix-bot/requirements.txt
python -m pip install -r services/matrix-bot/requirements-dev.txt
```

Run the complete Phase 0 verification suite without starting Docker containers:

```powershell
pwsh -NoProfile -File scripts/verify.ps1
```

Render Synapse and Element configuration without starting Docker:

```powershell
pwsh -NoProfile -File scripts/init_matrix.ps1 -RenderOnly
```

Rendering is strict: every `{{UPPER_SNAKE_CASE}}` token must be supplied, and unresolved tokens stop the script.

### 2. Initialize Synapse config and bootstrap accounts

```powershell
.\scripts\init_matrix.ps1 -StartAll
```

The script will:

- create `data/` folders
- generate a fresh Synapse config and signing keys if missing
- render `data/synapse/homeserver.yaml`
- render `data/element/config.json`
- start `postgres` and `synapse`
- register the admin account and bot account
- optionally start `element-web` and `matrix-bot`

### 3. Manual startup commands

If you prefer step-by-step commands:

```powershell
docker compose up -d postgres synapse
.\scripts\init_matrix.ps1
docker compose up -d element-web matrix-bot
```

## Element and Mobile Client Login

- Element Web: open `http://localhost:8080`
- Official Element Android/iOS:
  - choose custom homeserver
  - enter `SYNAPSE_PUBLIC_BASEURL`
  - login with the admin or test user credentials

For real mobile devices, `localhost` will not work. Use a LAN-reachable or public hostname with valid HTTPS.

## Suggested First-Time Room Setup

1. Login with the admin account in Element Web.
2. Create a room for announcements or customer service.
3. If you need encrypted messaging, enable room encryption from room settings.
4. Invite the bot user, for example `@matrixbot:your-server-name`.
5. Send `!ping` in the room to confirm the bot is active.

## Bot Commands

Bot commands work only in targets listed in `MATRIX_ALLOWED_ROOM_TARGETS_JSON`. Invitations to any other room are ignored, and internal publish requests for any other target return `MATRIX_ROOM_NOT_ALLOWED`.

- `!ping`: health check
- `!help`: show supported commands
- `!announce-test`: send a sample announcement message
- `!lottery-test`: send a sample lottery notification
- `!autoreply on`: enable auto-replies in the current room
- `!autoreply off`: disable auto-replies in the current room
- `!autoreply status`: show the current auto-reply state

If `MATRIX_ADMIN_USERS_JSON` is configured, privileged commands are restricted to those users.

## Business Webhook Integration

The bot exposes an internal endpoint:

```text
POST /internal/matrix/publish
Header: X-Matrix-Webhook-Key: <MATRIX_WEBHOOK_API_KEY>
```

Example request:

```powershell
$headers = @{
  "Content-Type" = "application/json"
  "X-Matrix-Webhook-Key" = "change-this-internal-api-key"
}

$body = @'
{
  "event_type": "lottery_draw",
  "route_key": "announcement",
  "idempotency_key": "draw-20260607-001",
  "message": {
    "body": "第 20260607 期已开奖，请及时查看结果。"
  },
  "metadata": {
    "issue_no": "20260607"
  }
}
'@

Invoke-RestMethod -Method Post `
  -Uri http://127.0.0.1:8081/internal/matrix/publish `
  -Headers $headers `
  -Body $body
```

Payload fields:

- `event_type`: business event type
- `route_key`: optional logical route key such as `announcement`
- `room_id`: optional direct room ID override
- `room_alias`: optional direct room alias override
- `idempotency_key`: optional deduplication key
- `message.body`: required text body
- `message.formatted_body`: optional HTML message body
- `metadata`: optional business metadata for logging or future extensions

## Test Flow

Run the following checks after startup:

1. `docker compose ps` shows all services healthy or running.
2. Open Element Web and confirm the admin account can login.
3. Create a second test user manually from Element if you temporarily enable registration, or use the Synapse registration script pattern.
4. Create an encrypted room and verify normal chat between two users.
5. Invite the bot and verify `!ping`.
6. Verify `!announce-test` and `!lottery-test`.
7. Trigger the webhook and confirm the message arrives once.
8. Replay the same `idempotency_key` and confirm the response is marked `deduplicated`.
9. Send a keyword that matches `MATRIX_AUTO_REPLY_RULES_JSON` and confirm auto-reply behavior.
10. Login from Element Android or iOS against the same homeserver.

## Production Deployment Notes

- Put Synapse and Element behind HTTPS.
- Use a stable domain before launch. Matrix IDs include the server name and cannot be changed later.
- Replace `localhost` URLs in `.env` with your real domain.
- Keep `MATRIX_SERVER_NAME` aligned with your public Matrix domain.
- Store `data/postgres`, `data/synapse`, and `data/bot` on persistent volumes.
- Restrict the bot HTTP port to internal networks only.
- Pin image tags in production instead of using `latest`.
- Add backups for the PostgreSQL database and Synapse signing keys.
- If you need voice/video later, add a TURN server such as `coturn`.

## Security Notes

- Never commit `.env` or generated `data/` files.
- Keep `SYNAPSE_REGISTRATION_SHARED_SECRET`, `MATRIX_WEBHOOK_API_KEY`, and bot credentials secret.
- Public registration is disabled in the Synapse template by default.
- Federation is effectively disabled in this starter by not exposing federation listeners; add it deliberately later if needed.
- The webhook port is bound to `127.0.0.1` by default.
- Review `MATRIX_ALLOW_UNVERIFIED_DEVICES` before production. Setting it to `false` is stricter but may require more device verification steps in encrypted rooms.

## Production Reverse Proxy

`infra/nginx/nginx.conf` is a starting point for production. Adjust TLS certificate paths, upstreams, and public hostnames before use.
