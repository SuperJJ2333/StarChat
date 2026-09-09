# Enterprise download delivery

Published the user-selected enterprise test IPA, unchanged. Static signature mismatch and additional libraries remain as reported in `artifacts/2026-09-08/ios-voice/enterprise-ipa-inspection.json`; website delivery does not establish successful device installation or working push credentials.

URLs:
- https://www.liuhetong888.com/download
- https://www.liuhetong888.com/downloads/ios/manifest.plist
- https://www.liuhetong888.com/assets/download-qr.png
- https://www.liuhetong888.com/downloads/ios/ChatFlow-0.3.53-59-enterprise-42d30a18.ipa

IPA SHA256: 42d30a18898a332ff381bbdf8c405801aed8aa3f3a86bf98a9bb12b6a791c45a (58,964,247 bytes). Downloaded public IPA hash matched the user's file. Public page, manifest and QR matched local bytes. QR decoded to the canonical HTTPS download page.

Deployment backup: `/opt/starchat/docs/verification/artifacts/2026-09-08/enterprise-download/backup-20260908T074502Z`. Nginx syntax check and reload succeeded. The config file was updated in place to retain its bind-mounted inode. Only five named static assets were deployed; existing admin/wallet files were not uploaded.

Routing: HTTP apex → HTTPS apex (308) → canonical www download (302) → page (200), verified from production host. HTTPS apex and /download redirect verified from workstation. Manifest returns application/xml; IPA application/octet-stream; QR image/png. Matrix versions and Android APK return 200; call gateway GET health reports status ok. Local workstation has intermittent TLS EOF; no certificate checks were bypassed.

Verification:
- Red: page/manifest/route implementation absent, three focused tests failed.
- Green: three focused tests pass.
- Frontend: 72 tests pass after removing non-token CSS colors.
- UI contract drift: PASS (17 components, 330 screens).
- Local desktop/iPad/phone browser checks: QR loads, no horizontal overflow or JS error; screenshots inspected.
- Public desktop screenshot inspected. Public mobile navigation was intermittently blocked by connection closures; local responsive screenshots and public file identity were verified.
- Repository full verification pending at time of this entry.

Specification self-review: requested install entry, manifest, QR, apex canonical route present; no Matrix/API/VoIP redirect; install status explicitly unverified.
Quality/security self-review: HTTPS links, immutable IPA filename and hash check, explicit MIME, no secret exposure, no signature bypass, backups and rollback path present.

Figma: remote synchronization unavailable; local export ledger and registry record this explicitly, no remote node or Figma PASS fabricated. Canonical design remains https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ .

Final verification: scripts/verify.ps1 completed with Verification: PASS. Backend 1347 passed / 31 skipped with one existing Starlette deprecation warning. Public desktop/iPad/phone browser checks all passed after bounded retries (screenshots public-desktop.png, public-ipad.png, public-phone.png). No JS errors or horizontal overflow; QR loaded. Device IPA installation and remote Figma synchronization remain unverified, not claimed complete.

Homepage follow-up: enabled iOS anchor in platformButtons(), href /download, label 0.3.53(59) enterprise test, replaced unavailable/preparation copy. Red homepage test observed, all 73 frontend tests green, UI drift PASS. Patched only the three exact text blocks on production, preserving unrelated admin source. Backup home-before-20260908T083413Z.js in deployment evidence directory. Live browser clicked homepage iOS link and reached /download with installation link visible. Screenshot homepage-ios.png. Specification and quality self-review: correct target/version, no disabled control, no unsupported claim that enterprise signing is validated. Remote Figma synchronization remains unavailable as previously recorded.
