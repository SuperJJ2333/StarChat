# In-place MFA setup implementation

Approved user request; ADR-0057 records the authentication scope. Own wallet_mfa.py service/router, manual_wallet_api.dart, manual_mfa_page.dart and their tests. Preserve other work.

1. Red tests: old valid session plus correct password can enroll; wrong password/revoked device still denied; scoped proof permits enable and rejects expired, tampered or wrong family proofs.
2. Implement authenticated encrypted short-lived proof, pending credential reauthentication and optional proof at enable. Preserve legacy recent-session behavior when absent.
3. Integrate memory-only proof in Flutter and in-page password refresh for pending enrollment.
4. Update OpenAPI and run focused service/route/client tests, then repository verification; scope review followed by security review before deployment.
5. Production deployment and a new debug artifact require verified source/contract and signature continuity. Do not claim release until installed and checked.
