# Infrastructure Agent Rules

Inherit all rules from `/AGENTS.md`.

- Treat templates as source and `data/` as generated runtime output. Never hand-edit generated configuration as the permanent fix.
- Template expansion must replace exact `{{UPPER_SNAKE_CASE}}` tokens and fail on unresolved tokens.
- Production container references must be explicit release tags or immutable digests; never use `latest`.
- Keep Matrix, business, audit/report evidence, and media persistence logically separated.
- Secrets must come from a production secret manager. Compose `.env` is development-only and must remain ignored.
- Synapse and media storage may store only encrypted user content. TURN/SFU must not terminate user E2EE.
- Validate Compose rendering, health checks, backup/restore, and migration behavior before deployment changes are accepted.
- PowerShell automation must support UTF-8 without BOM and use `-LiteralPath` for filesystem operations.

