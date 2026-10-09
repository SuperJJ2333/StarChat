# iOS0.4.44+2213 unsigned signing handoff

User requested an iOS IPA to sign independently, then return for distribution. This task prepares the latest shared source; final enterprise-signed distribution awaits returned bytes. No production or Apple upload was performed.

## Source and artifact

- Base main: ee558632368d04bbd712193fa53d810edf4fdad7. Candidate: 2f423a3499727f7080f4a8bf1d8c3a8225b3d5ba. All mobile Git blobs equal the verified main; source-and-gates.json binds reused shared5758PASS/9conditional skips/analyze0. No new application behavior in this packaging task.
- CI: https://github.com/SuperJJ2333/StarChat/actions/runs/37919997058, attempt1, candidate branch only. Remote main remains be207f0f.
- Full device job113785366978 SUCCESS. Production29plugins/46frameworks, scanner retained. Actual macOS Ruby permission tests2PASS/0skip; source→built usage descriptions and binary permission implementations verified. CocoaPods102.3s, Xcode227.6s, Runner87.9MB.
- IPA: ChatFlow-0.4.44-build2213-unsigned.ipa,34839152bytes, SHA256 3cfa40ed6bae4d91e6b702162f5d9ccbfb2a3620bcedf9021b6e53662347b952. Bundle ID com.liuhetong.liuhetongMobile, iOS/iPadOS16+, arm64 iPhoneOS.
- 479Payloadfiles, CRC/no duplicate names/executable permissions/actual Mach-O platform, SQLCipher six exports and statistics source asset checks passed. Source entitlement file is copied unchanged; no Runner signature/profile. Some upstream frameworks have signature resources; enterprise signer must re-sign the complete app and frameworks.
- Artifact11611333284 outerZIP digest4500f8231c39af3ce3a08c30d73c0d4fb450f225cc2b0e49eb288527cac6df2f and device evidence11611433142 digest0873805aca5dc98f65b170b0b356fd0ac667e90b5df61c29701921d2aef303a5 verified against API, CRC and exact run/head.
- Independent prebuild SPEC then QUALITY PASS; actual artifact SPEC then QUALITY PASS with all46framework SHA checks.

## Native gate

Simulator job113785366949 SUCCESS: 13 migration +4 SQLCipher/WAL +1 Keychain =18 passed. All three targets attempt1/exit0, no VM-service stall or hard timeout. selected-source.json binds exact candidate/run/attempt, iPhone15/iOS26.2. Artifact11613191231 digest1bcad2485da4709d40a0fa0b9eaab29d8e29585b78c053dd174edac355f694c5 verified. Target wall times1050.24/232.42/267.51s; first Xcode build511.8s, actual migration tests5m28s (250000-record migration192573ms with continuing timer ticks). These are synthetic batch-migration timings, not a claim of physical-device UI frame performance. The synthetic iPhone15/iOS26 test host excludes only mobile_scanner because of its upstream lack of arm64 simulator slice; full device IPA retains every production plugin. This does not prove physical-device enterprise upgrade, push or audio behavior.

## Tests, timing and limitations

Old workflow hardcoded2205: new version contract RED1. Minimal six-line CI constant update: focused36PASS/3.02s. Windows permission contract1PASS/1Ruby skip, replaced by real macOS2PASS/0skip. A local command initially named a nonexistent test file, collected no tests; path corrected and real gate run. No product source fix or hidden failure. Existing Flutter SPM migration warnings are upstream plugin notices; explicit CocoaPods path succeeded.

Source freeze18:48:50+08, CIcreated18:49:56+08. Device/native run in parallel, durations from CI receipts rather than added together. Native completion 2026-10-09T19:24:37+08:00, CI wall 2081s. Parallel job durations are not added together. Final receipt records exact stage intervals; initial preparation before source-freeze has no precise start record.

## Signing and delivery

IPA copied to C:/Users/Administrator/Downloads/ChatFlow-0.4.44-build2213-unsigned.ipa and primary ignored delivery, both SHA checked. Runner.entitlements, build-manifest.json, toolchain.txt, SHA256SUMS.txt and SIGNING-NOTES.md accompany the candidate in delivery.

Source aps-environment=production is expected configuration, not actual signed rights. Retain the Bundle ID and matching enterprise profile. When old account/chat data must survive, preserve prior signing AppID/Team/Keychain relationships and verify a no-uninstall overwrite on the original phone. Final signature/profile/entitlements and signed-byte binding await the user's returned IPA. No website link, update popup, Android channel or production service changed.

Evidence: docs/verification/artifacts/2026-10-09/ios2213-signing/. Candidate package is immutable; future signing/distribution should use its exact SHA as source provenance.

Final state: both CI jobs and actual artifact reviews accepted. Candidate packaging/handoff complete; enterprise signing, final signed-byte verification, physical-device overwrite and later channel distribution remain dependent on the returned signed IPA.
