# Android 0.4.47+2216 publication preparation

Preparation only; no real APK, gate bundle, package or execution review is generated here. Root owns the final build and publication. This directory is the only changed scope, in the reused clean `im-worker-active-lease` worktree. Reference release framework is the reviewed 2215 code at `35f59abbb6bdaa0fe6c826aaff904130bb6dea76`; the approved source is root's 544b61b6 revision. The user explicitly requested the new Android version and ordinary update popup. Root arranges independent SPEC/domain → QUALITY/security before execution.

## Fresh live baseline

HK was read once through the existing jumper/wrapper at **2026-10-16T02:36:33.090654Z**, SG once at **02:36:39.153576Z**, both exit 0. The projection keeps SQL read-only, connection timeout 3 seconds, statement timeout 5 seconds, docker exec 12 seconds; Docker inventory calls 10 seconds, AWS calls 30 seconds and outer transport 180 seconds. No environment secrets or user data were output.

- Android **0.4.46+2215**, iOS **0.4.46+2215**, minima **3/3**; all ten settings captured. The new Android version/build/notes are the only intended settings changes. Ordinary popup is enabled by latest build; minimum build is preserved.
- **35** running containers with exact name/ID/image/restart/start time; schema **0095_wallet_source_alerts**. Current API image is `sha256:b1316787e2a1bce10f8b9c3aaaf333e11822b8f36f4b939025b3abeb5e99ffc6`, different from the old October 12 baseline. No service restart/revert is permitted by this task.
- Permanent guard `46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b`, probe `2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15`, unchanged; only read and hashed.
- Current immutable Android2215 package: **73262170 bytes**, SHA256 `4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6`. The HK2216 target file is absent. This old package is a preservation/rollback input, never the new artifact identity.
- Seven static files are captured as original bytes. iOS's published `ChatFlow-0.4.46-2215-enterprise-4087d408.ipa` reference, five preserved static files, all iOS settings, minima, URLs and other ABI aliases remain unchanged.
- CloudFront **17 rules / Deployed / ETag E1IM4EOPHS76S7**, exact account/role/distribution and bucket policy. Preparation derives only a new immutable2216 HK-origin behavior, yielding18 rules. Runtime still must use fresh preflight and ETag CAS.

The captured baseline is not permission to skip preflight later. Any changed source/settings/static/service/cloud identity refuses mutation; never silently restore old services or refreeze unexplained drift.

## Minimal changes and tests

`adaptation.diff` compares all executable package/executor/runtime inputs against the reviewed2215 Git version. Changes are target and baseline versions/names/hash/bytes, new notes, dated private staging paths, two known builder aliases, and a source-dependency preservation check. UNKNOWN markers, single attempt mutation, inflight protection, exact package/review binding, hash/size verification, stage order, CDN-before-alias checks, static CAS and rollback remain intact.

The new notes are: “优化启动和聊天记录加载，完善图片、视频及 GIF 发送预览，恢复超级表情自动播放，改进权限提示体验。”

- `version-red.log`: new2216 tests ran real old2215 behavior under renamed imports; 32 tests, exit1, 1 failure/15 errors from wrong target/baseline, not missing modules.
- `version-green.log`: 32 PASS / 9.748s after minimal target/baseline adaptation.
- `aliases-dependencies-red.log`: 3 cases; missing actual `rebuild`/`signature` aliases errored, four selected settings-dependency drifts and absence escaped the old preflight. Five failing subassertions/one error are retained.
- `all-boundaries-green.log`: **35 PASS / 13.101s**, exit0. Includes original three static rollback/raw-byte regressions, unknown commit/replay protections, missing review/source/gate refusal, iOS/minima preservation, and the new boundaries.
- Builder aliases accept actual `source-build`, `rebuild`, `signature` in addition to existing known names. Every original row remains required to succeed, including extra alignment/final checks; failed, duplicate, missing, or lookalike skipped phases are rejected. No synthetic three-row receipt replaces actual builder output.
- Tests use synthetic APK/evidence and transport/filesystem doubles only. They do not certify the new APK or execute SSH/cloud/production mutation.

## PostgreSQL evidence reuse

`postgres-closure.json` proves `transact` is byte-identical to the reviewed source, the full module and six-case PG test differ only by explicit version/module/trace/notes substitutions, and four settings/audit/database dependency file hashes match historical evidence, current root Git and the actual selected production files. Live preflight now also rejects drift/missing dependency hashes.

`reused-postgres-2214.log` remains the historical **6 PASS / 8.16s** result. No PostgreSQL test, restore or write was run this time. Current API image differs; the closure claims source/dependency/schema identity only, not current image, ORM or runtime equivalence. The new target and metadata validation are covered by the fresh offline tests.

Global `scripts/verify.ps1` was inspected and is outside this artifact-only task; user/root explicitly requested bounded preparation without global suites. Root's existing `.env` limitation and final shared/native/build requirements are not replaced by these offline tests.

## Actual input contract and next step

See `usage.md`. Root supplies the real final APK, `receipt.json`, original complete `steps.tsv`, `mobile-inputs.json` and the three gate reports with their actual hashes. No new SHA, artifact bytes or PASS fields are invented here. The package checks source files/lock, ARM64 package/version/fixed75b31 signer, final bytes/hash, exact successful steps and three hashed gate inputs; it does not establish the semantic truth of a handwritten report, so independent review must read them.

After package creation, root binds SPEC/domain then QUALITY/security reports to its exact freeze/runtime/artifact/source hashes and a fresh operation ID. Executor defaults to plan-only. Remote execution requires explicit `--execute` and that reviewed package, then the ordered immutable upload/CDN/alias/static/three-setting workflow. This author has performed only the two baseline reads and local tests. No package publication or production operation has run.
