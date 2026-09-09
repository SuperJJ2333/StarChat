# Enterprise IPA download page deployment

User authorized on 2026-09-08: add HTTPS installation, manifest and QR to www.liuhetong888.com/download; apex homepage redirects there.

Goal: deliver an installation entry for the exact user-supplied enterprise test IPA, without representing static signing issues as resolved.

Architecture: standalone download.html reuses existing landing CSS/tokens. Versioned IPA and manifest under /downloads/ios/. QR points to canonical HTTPS download page. Only exact apex / and /download redirect; Matrix/API/VoIP paths are preserved. Back up production files and nginx config, validate nginx before reload, verify public TLS, content types and full IPA hash.

Owned paths: frontend/download.html, frontend/src/styles/download.css, frontend/assets/download-qr.png, frontend/downloads/ios/manifest.plist, scripts/enterprise_download_routes.py, scripts/tests/test_enterprise_download.py, scoped registry/ledger entry and verification artifacts. Existing admin changes are not deployed.

- [ ] Red tests: required page links, manifest identity/version/HTTPS, IPA hash, QR target, nginx exact routes preserving existing configuration.
- [ ] Implement page, manifest, QR and additive nginx patch.
- [ ] Focused green and frontend/repository verification; specification review then quality review.
- [ ] Upload exact IPA and only owned assets; backup, nginx test/reload with rollback.
- [ ] Verify public URLs, redirects, MIME, QR decode and hash. Device install remains separately unverified.

Figma remote tools unavailable. Record local contract and unavailable remote synchronization honestly; do not fabricate remote node IDs or PASS evidence.

Delivery status: implementation/deployment and public HTTP/HTTPS redirect, manifest MIME, full IPA hash, QR decode, responsive browser checks completed. Frontend72 / focused3 / UI drift / full repository verify PASS. Nginx template includes durable route configuration. Verification: docs/verification/2026-09-08-enterprise-download.md. Figma sync unavailable and actual enterprise IPA install unverified.

User follow-up authorized: enable homepage platformButtons iOS link to /download, show 0.3.53(59) enterprise-test label and remove preparation copy. Patch only exact production block to preserve unrelated admin edits. Red homepage link test observed before implementation; frontend and browser verification required.
