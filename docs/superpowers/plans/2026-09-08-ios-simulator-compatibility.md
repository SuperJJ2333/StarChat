# iPhone compatibility diagnostic execution

User authorized choosing available iOS versions and running simulator tests on 2026-09-08. Extends approved iOS diagnostic plan; use subagent-driven-development for native tests and independent direct-room audit.

Goal: test possible iPhone15-compatible runtimes without claiming to reproduce third-party enterprise code or unknown device state.

Ownership: root CI workflow, SDK integration dependency, synthetic fixture generation and evidence; native agent integration_test/ios_compatibility_test.dart only; direct-room agent new regression test only.

- Discover actual installed runtimes on macos-15 with Xcode16.4 and26.3. Select iOS18 and iOS26 respectively, record exact chosen versions; do not silently substitute another major version.
- Use fresh iPhone15 simulator devices, no real accounts. Generate AAC/M4A/WAV and H264/HEVC video from synthetic signals. Run real native audio/video plugins and SQLCipher/Keychain.
- Run seed then verify in separate app processes, retaining the app container. Verify synthetic history survives and key bytes agree without printing keys.
- Independently reproduce direct-room duplication under transient sync errors using fake gateways. Only implement a bounded fix after a failing behavioral test and review; do not delete/merge rooms or weaken E2EE.
- Publish only allowlisted diagnostic sources onto a separate branch; no TestFlight/enterprise upload, signing secrets or production data access.
- Record exact runtime, pass/fail and capability gaps. Review specification then quality before claiming completion.

## Proven media defects, 2026-09-08 continued execution

Second run reached native assertions on iOS18.6 and26.2: each 11 pass / 4 fail. Direct WAV with audio/wav passes while production engine with null MIME fails. H264 and HEVC .mp4 paths pass; identical extensionless files fail OSStatus -12847. User instructed continuing the authorized compatibility investigation/fixes.

Bounded design: root adds RIFF+WAVE recognition to voice source MIME, preserving bytes and other containers. Video agent owns media_cache.dart and video_playback_extension_test.dart, migrates recognized cached MP4/QuickTime files to a fixed correct suffix within the existing cache (rename, no extra retained plaintext copy), and keeps cache validation/quotas/cleanup. Native test must use the production cache resolver for this path. Other source, UI and E2EE/key behavior remain outside these fixes.

Harness correction: Flutter3.44.9 test defaults uninstall=true. Explicit --no-uninstall in both phases is required; the original second-phase design was insufficient. Second run was cancelled after native red evidence, not treated as a valid restart test. Next run includes test/step timeouts, --no-dds, and simulator diagnostics. Verify seed container/file exists before phase verify.

Final correction and outcome (2026-09-09): removed --no-dds because Flutter's integration test comparator requires its custom DDS stream. Retained --no-uninstall and all assertions. Run 34244984251 succeeded on iPhone 15 / iOS 18.6 and 26.2, each with 15 seed and 2 restart tests passing. Production fixes, focused regression tests, specification and quality/security reviews, and repository verification are complete. Detailed evidence and remaining history-loss limitations are in docs/verification/2026-09-08-ios-simulator-compatibility.md. No release/package publication was performed.
