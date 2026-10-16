# Android 2216 delivery evidence consistency

Verdict: **PASS** for consistency of the recorded publication, audit, public verification and local backfill. No new issue found. Review was local/read-only except this report; no tests, network calls or production operations were repeated.

All nine requested phase receipts are PASS and bind freeze `5df015a69df956450a6e1d8ec9c728324fce9c3bfa1be2863f18385aa3d551a6`. Upload/assembly identify APK `db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039`, 73,262,170 bytes. HK install retained the prior alias; CloudFront first reported InProgress, then confirmed Deployed and HEAD/CORS before the alias switched to build2216. This progression does not mislabel the initial CDN update as deployed.

Publication completed at 2026-10-16 **11:04:15 +08** (03:04:15 UTC), with PUBLISH_PASS and trace `android2216-experience-20261016-2216`. Audit at **11:04:30 +08** confirms Android 0.4.47+2216, iOS unchanged at 0.4.46+2215, both minimum builds 3, and exactly three audited keys: Android latest build, latest version and update notes. The ordinary-update configuration is verified; these receipts do not themselves demonstrate a client visibly displaying the popup.

Workstation public receipt records eight HTTP requests, all eleven checks true: direct/CDN HEAD, CORS, Android registry/page, preserved iOS manifest and three unauthenticated route rejections. TLS verification remains enabled. This lightweight evidence proves access/size and metadata; it is not a second download/hash/signature verification of the entire APK. The owned tunnel cleanup receipt reports only its own process stopped or already exited. No remaining inflight or outcome-unknown marker was present at this checkpoint.

Local backfill receipt binds the actual publish and audit hashes. Independently verified all four current local file hashes and both receipt hashes. Local iOS metadata reconciliation is not a separate iOS production publication; reviewed admin cacheEpoch/security additions remain preserved by the approved target hash.

Evidence identities:

- publish.json: `972488af8f8a34fffd257aabbef7db504f639bf9e08cc227a9a2c1b407ce3f6a`
- audit.json: `a1b3b1316afe8b97c40f6f6e0d1f7e21185dfe95f4dc481730723e163ab00d5e`
- public-check/public-receipt.json: `0141471fd8f11beb261c31c0e6530ada892d335de3ebfed6b2a23a4b2a432966`
- local-backfill/applied.json: `5a2d4d69816f31b8493a8e255b61ce2110f43fd7155773b27890e2d0bce84c9b`

Final claims must retain the known libcrypto 16KiB limitation and absence of ARM64 real-phone acceptance. Matching-source Debug emulator tests, server metadata/audit and public HEAD checks do not establish those gates. No separate iOS release or blanket warning-free/full-repository success should be claimed. Final source commit/documentation bookkeeping remains root-owned.

Reviewed: 2026-10-16T11:06:14.0024220+08:00.

