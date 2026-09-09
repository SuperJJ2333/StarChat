# Wallet interaction polish implementation plan

User approved the preceding proposed workflow with “请你优化以上流程”. Root owns panel, its tests, cache entrypoints and verification/runbook updates. This is frontend orchestration only; existing backend authentication, state transitions, idempotency and audit contracts remain unchanged.

Design: expose a clearly labelled password-free current-state check using existing read-only APIs; retain the single authorized incident process and separate fund recovery. Explain what the credential authorizes. Replace pause reason-code input with a Chinese confirmation and fixed OWNER_CONTROL_PAUSE while preserving any pending original metadata. During a command, coalesce refresh requests and execute one read-only refresh after completion, showing waiting status immediately. Resolve queued requests on disposal. Never replay a command as part of refresh.

- [x] Write failing tests for password-free check, pause reason/confirmation and delayed refresh coalescing/disposal.
- [x] Implement minimal panel changes and loading feedback; verify focused tests then all frontend tests.
- [x] Review specification compliance then quality/security, update runbook and evidence; run required verification script.
- [x] Publish only changed static files with cache versions and rollback copies; verify public hashes. No live financial actions.

No additional security ADR is required: all mutations still use the same authenticated endpoints and proofs; read-only checks already have their existing admin session requirements. Existing approved incident workflow design continues to apply. Remote Figma remains deferred under the earlier approved design.
