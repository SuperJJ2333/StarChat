# Matrix Notification Bot Agent Rules

Inherit all rules from `/AGENTS.md`.

- This service is a notification bot, not a moderation bot and not a financial authority.
- Deny all room targets unless they are explicitly configured in `MATRIX_ALLOWED_ROOM_TARGETS_JSON`.
- Never auto-join an unapproved invitation, ordinary private room, or ordinary group room.
- Do not request, export, log, or persist keys for user conversation rooms.
- The internal publish endpoint may render notifications but may not change ledger, red-packet, wallet, approval, or support state.
- Validate room authorization before alias resolution, join, or send.
- Log room IDs and event IDs only when operationally necessary; never log message bodies or decrypted content.
- New behavior requires focused pytest coverage and must preserve idempotent publishing.
