# Phase 0 Task 4 Verification — Notification Bot Room Policy

**Verified:** 2026-08-12 (Asia/Hong_Kong)

## Red evidence

The initial policy test failed during collection because `app.room_policy` did not exist. After the pure policy was added, the wiring tests produced three intended failures:

- `Settings` did not expose `allowed_room_targets`.
- `send_message()` reached Matrix room access before rejecting an unauthorized target.
- `_on_invite()` joined an unauthorized room.

The API behavior test returned HTTP 500 instead of the required stable HTTP 403.

## Green evidence

Command:

```powershell
$env:PYTHONPATH='services/matrix-bot'
python -m pytest tests/matrix_bot -q
```

Result:

```text
8 passed in 0.78s
```

Additional verification:

```text
AST parse PASS: 10 files
docker compose --env-file .env.example config --quiet -> exit 0
```

## Enforced behavior

- Empty allowlist denies every room.
- Send authorization occurs before room resolution, join, or Matrix send.
- Unauthorized invitations are logged without message content and ignored.
- Authorized invitations are joined.
- Internal publish returns HTTP 403 with `MATRIX_ROOM_NOT_ALLOWED` for an unauthorized target.

## Files

- Created `services/matrix-bot/app/room_policy.py`
- Created `tests/matrix_bot/test_room_policy.py`
- Created `tests/matrix_bot/test_api_room_policy.py`
- Updated `settings.py`, `matrix_client.py`, `api.py`, Compose, `.env.example`, and ignored local `.env`
