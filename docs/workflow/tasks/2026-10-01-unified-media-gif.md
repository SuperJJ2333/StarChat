# Unified media and GIF original fidelity

Status: investigating/design approved by standing user authorization; no new product code or publication yet.
Spec: ../../superpowers/specs/2026-10-01-unified-media-gif-design.md
Plan: ../../superpowers/plans/2026-10-01-unified-media-gif.md
Worktree: C:/Users/Administrator/.codex/worktrees/unified-media-gif-20261001/StarChat
Branch: codex/unified-media-gif-20261001; baseline main 7d8b8d6ab84bc2d81a8b1aa786455f1442b26e18.
Authorization: user explicitly requests modifying media layer and unified entrances/exits; earlier in this session user preapproved autonomous plans/ADRs and Android update publication/iOS candidate handoff. No repeated approval needed. Current Android2195 published; iOS2195 candidate SHA5699c3d7 exists but does not include this task.
Reliable initial clock: 2026-09-30 20:07:38 UTC / 2026-10-01 04:07:38 +08. Earlier investigation start time unknown.

Evidence before this task: server chatflow_media_dedup_enabled=true and deployed module SHA4f177e1b5bd5bc6a42986d46414fd4326b5b23096ec95a21e3ad93d7788700e8 equals local. Emoji vault uploadEncrypted uses random MatrixFile.encrypt, while ordinary chat uses ADR-0060 deterministic prepared envelope. GIF chat/Moments picker paths generally preserve bytes but standalone image preprocessing and .jpg gallery export are bypass risks.

Ruling: unify client policy/identity/read/export interfaces, retain protocol and privacy domains — accepted prior answer and frozen architecture disallow migrating chat ciphertext into business storage or global plaintext dedup — if user intended a single cross-domain public URL, that would need a separate privacy/permissions architecture rather than silently exposing chat.
Ruling: skill approval pauses overridden by user's explicit standing autonomy authorization; still write spec/plan and perform independent domain/security review before frozen candidate. One child implementer at a time; root owns independent files only.

Next: Task1 red/green and collection deterministic adapter; root audits the remaining upload/read/export boundaries. No server writes planned for client unification.
Outstanding inherited gap: iOS fully suspended new-event wake/sync/decrypt discovery remains unimplemented; no K80 endurance/device performance measurement.
