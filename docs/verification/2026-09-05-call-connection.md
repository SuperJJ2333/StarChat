# Cross-network call connection and immediate-answer repair

Approved scope/ownership: `docs/superpowers/plans/2026-09-05-call-connection-reliability.md`. User requested investigation, optimization, tests and guidance on bandwidth/nodes/managed service. No purchases or RTC architecture replacement.

## Evidence and diagnosis

- Existing MI 6 logs (only allowlisted timing/quality fields retained) reproduced answer signaling 1427 ms, then ICE connection 21723 ms, ultimately TURN relay. Another voice call connected after 3582 ms. Network provenance for those actual user calls is not known.
- Coturn's TLS listener was not running because nobody:nogroup could not read a root:root 0600 key shared with nginx. Certificate validity/secret equality were checked without exposing key/credential material. This supersedes the previous upstream-firewall inference in docs/TURN.md.
- Existing Matrix SDK 0.34.0 caches TURN credentials indefinitely; production credentials expire in 3600 seconds. This is a separate reproduced code defect, not proof it caused the particular 21.7-second call.
- Controller tests reproduced connected being overwritten after answer/start, double answers, termination/disposal races and indefinitely pending route/cleanup. Adapter tests reproduced old answer callbacks connecting a replacement session and missing already-connected/ended snapshots.

## Fixes

Controller uses call-generation and terminal guards, applies state promptly, bounds preparation/answer with the existing connection timeout and never waits for cleanup to update terminal UI. Video route completion no longer gates connected UI. Caller fast-answer/late-start paths are also guarded.

Adapter synchronously detaches ended sessions/resources before async cleanup, captures the answered session, ignores stale callbacks and deduplicates connected events; late attachment reads connected and ended snapshots.

Account-scoped in-memory TURN cache refreshes before expiry, at most every five minutes; parallel requests share a Future, startup prewarming is nonblocking and discovery has a three-second timeout. Expired credentials and late timed-out results are not reused. Existing direct-connect fallback, Matrix signaling and media encryption remain intact.

Production coturn now mounts an isolated certificate directory: root:65534 directory 0750, key 0640. Nginx key mode remains 0600. A scoped Certbot hook updates the isolated pair and restarts only coturn after successful synchronization. Production change was exactly one bind source replacement; no unrelated Compose source was uploaded. Backups/rollback are on server in `/opt/starchat/releases/turn-tls-20260905/`.

## Tests and limits

- 74 focused Flutter call tests passed; final focused analysis passed.
- Certificate infra suite: 15 passed, including five focused certificate/renewal tests and Linux permission verification.
- UDP/TCP/TLS authenticated synthetic allocations and bidirectional relays all pass after deployment. Allocation totals: 157.7 / 161.9 / 360.2 ms; relay round trip approximately 154 ms.
- Nine real WebRTC data-channel tests forced both peers through relay: all passed, 770–1019 ms to establish, 154–168 ms payload echo. No real calls, camera or microphone used. Browser trusted TLS verification remained enabled.
- Local Windows DNS uses a proxy fake-IP; probes explicitly targeted production IP (TLS preserving hostname). These tests do not represent all mobile carriers or establish provisioned bandwidth/saturation capacity. Real double-device audio/video tests are still required; do not promise sub-second phone calls.
- Full repository gate: backend/worker 338 passed, 19 skipped; mobile boundary 47 passed, four existing call source-shape tests fail, matching earlier verified baseline failures. UI contract 17 components/330 screens and OpenAPI drift checks pass. The full gate is not green.
- Independent review was specification-first then quality/security; findings in controller and adapter were resolved with additional red/green tests. No encryption/auth/financial boundary changed. Logs contain timing, candidate type and aggregate quality only, never media or credentials.

## Capacity recommendation

No evidence currently identifies bandwidth saturation as the primary cause. Fixes above precede spending. If remaining calls have high relay RTT or route-dependent loss, evaluate a TURN node closer to users or a managed TURN service with UDP/TCP/TLS and 443 fallback while preserving device encryption. Increase bandwidth only after measuring peak relay egress, packet loss and concurrency. A managed RTC replacement is a separate signaling/media architecture and security decision.

Artifacts and complete red/green/probe evidence: `docs/verification/artifacts/2026-09-05/call-connection/`.

## Device delivery

Built standard ARM64 debug from source without obfuscation/packing, versionName 0.3.37 / versionCode 2040. Artifact `ChatFlow-0.3.37-arm64-debug-call-connection.apk`, SHA256 `c4a17b6fe0a4a7ffcdc41978599080bb000ec323914ea964f2ae8afe8eef44ce`. MI 6 `cbd0156b` non-streaming reinstall succeeded; no uninstall/data clear. Update time 2026-09-05 17:39:17; installed base.apk hash equals the artifact. MainActivity launched. No production APK/update popup published. Existing Flutter plugin KGP migration warning remains; build succeeded.

One controller-agent log-path typo created empty directories outside the repo at `D:/pythonProject/docs/verification/artifacts/2026-09-05/call-connection`. No files were written there. Automatic approval review rejected empty-directory deletion with `blocked by policy` and no more detailed reason; no bypass attempted. All actual evidence is under the repository's docs/verification.
