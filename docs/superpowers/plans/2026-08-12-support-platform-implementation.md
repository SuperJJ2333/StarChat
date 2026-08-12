# 六合通 Phase 3 Support Platform Implementation

## Scope
Implement server-authoritative official support identities and ticket queue lifecycle without reading Matrix plaintext. Support records store only metadata and room identifiers.

## TDD tasks
1. Add support models/enums and migration for identities, tickets, assignments.
2. Add service operations: identity view, open, assign-next (least active), transfer, close.
3. Add authenticated API endpoints with role checks and stable responses.
4. Add OpenAPI contract and focused tests.

## Invariants
- Official badge/color/number/description come only from business API.
- Queue metadata never contains message plaintext.
- Only support roles can operate tickets; supervisor/admin can transfer/close any ticket.
- Assignment is deterministic by online flag, skill match, then active ticket count.
