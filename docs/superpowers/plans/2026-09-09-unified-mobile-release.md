# Unified mobile release implementation plan

> For agentic workers: use subagent-driven-development task by task, with specification review before quality/security review.

**Goal:** Integrate published Android 0.3.68/2072 business functionality with the reviewed iOS compatibility, history, direct-room and request-context fixes; distribute iOS first, then deliver the same fixes to Android.

**Approval:** User explicitly requested this sequence on 2026-09-09. Existing isolated workspace V: on codex/mobile-parity-20260909. Inputs are exact commits afc9d15d (iOS fixes and deployment evidence) and 4912d062 (published Android 2072), not unrelated uncommitted root work.

**Architecture:** One shared Flutter source tree. Merge feature histories rather than replacing platform folders. Keep native iOS permissions, audio/CallKit/PushKit, SQLCipher and key continuity intact. Preserve precreation pair arbitration and the chosen labeled acceptance context. Combine Android image comments/detail/replies/emoji and retention with iOS account-scoped revision/persistence/optimistic-write guards. Statistics HTML must remain byte-identical to the verified 2072 resource. Keep existing E2EE/media integrity invariants and account logout isolation.

- [x] Merge Android release commit without committing; resolve overlaps by owned module, inspect automatic merges too.
- [x] Moments task owns moment_models/page, comment/detail integration and Moments tile; retain iOS ticket/revision/confirmed-write behavior while adding Android interactions. Run both branches' existing regression tests as red evidence; add focused missing combination tests before fixes.
- [x] Cache task owns cache_repository and Moments image grid/viewer/provider/cache files; preserve stable content identity, account isolation, failed-fetch retained images and iOS serialized snapshots. Run both test sets and add combination regressions.
- [x] Root owns app wiring, profile identity, version/workflows, contract registry and migration-head merge. Keep pair/greeting/native paths; reconcile generated OpenAPI and run repository gates.
- [ ] Review specification first, then quality/security; full Flutter tests/analyze, statistics HTML browser tests, backend/contract/migration verification and native iPhone simulator jobs.
- [ ] Build version 0.3.69 with monotonically increasing build 2073 for both platforms from one shared source commit. Distribute iOS first through confirmed channel; do not claim enterprise OTA from an App Store-signed IPA. Then Android standard ARM64 source/rebuild/alignment/fixed signer gates and publication, preserving Android 2072 until successor validated.
- [ ] Record shared source commit, native differences, artifact hashes, release order and any real signing/distribution blocker. No destructive history/key migrations or unrelated wallet changes.

Figma UI delivery applies to merged visible functionality. Preserve existing registered design components; record actual remote availability honestly and use the documented hotfix deferral only if remote tooling is unavailable.

