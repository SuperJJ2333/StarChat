# Unified media and GIF fidelity implementation plan

> **For agentic workers:** Use subagent-driven-development task-by-task; one implementation child at a time, root may own independent integration files. User has preapproved plans/ADRs/autonomous execution. Temporary skill artifacts are placed in docs/verification/artifacts/2026-10-01/unified-media/, overriding .superpowers defaults.

**Goal:** One shared media policy for size-bounded initial image compression, verified reads and format-correct exports; compressed GIFs remain identical across collection/re-send/forward/save/Moments.
**Architecture:** Shared client MediaAssetGateway with existing Matrix and business transport/cache adapters. Keep encrypted chat and business media storage and authorization domains separate.
**Tech Stack:** Flutter3.44.9/Dart3.12.2, vendored Matrix, existing Android/iOS gallery APIs and business API.
**Spec:** ../specs/2026-10-01-unified-media-gif-design.md

## Global constraints

GIF20MiB/4Mi canvas pixels/128Mi cumulative decoded pixels; current caches and scheduling budgets unchanged. No global bytes/Future cache; no recovery/room keys, plaintext attachment or plaintext hash to business/push/logs. ADR-0060 algorithm unchanged, no cross-user plaintext dedup. Preserve old capabilities, mxc and storage paths; no destructive migrations. No shared file concurrent editing. Keep other main WIP. Releases require fresh version reservation and stable signer.

## Review focus

Disguised GIF headers; corrupt/truncated animation; export of loaded thumbnail instead of original; MIME/length mismatch after begin; stale account/lease across async reads. Test real GIF bytes and observable codec/transport calls, not only source strings.

### Task 1: Shared original policy and encrypted collection

Owner child image_budget after unified_media_core handoff: create lib/features/media/media_asset_gateway.dart, image_compression_policy.dart and relevant tests; matrix_e2ee_client.dart vault uploadEncrypted, _sendMedia before sizing/thumbnail/cache and lease sendEncryptedAttachment routing; content_addressed_media.dart as required for real shared Matrix prepared exit; matrix_emoji_vault/emoji_vault tests and pinned image dependency. Root does not edit matrix_e2ee_client while child owns it. No Moments/UI files.

Interfaces: expose MediaAssetGateway.inspect(Uint8List bytes,{required String mimeType,required String filename}) returning bytes/mimeType/filename and isGif; prepareImage(bytes,{required Future<Uint8List> Function(Uint8List) transform}) uses shared bounded compression: compliant GIFs reuse bytes, larger GIFs retain animation while shrinking, static output is checked against budget. ImageCompressionPolicy.prepare(bytes,{transform?}) supplies shared default processing. readOriginal(loader,{String? expectedSha256}) verifies supplied trusted digest without permanent caching. readFile(loader,{ensureCurrent?}) verifies file availability without whole-file allocation and retains caller authorization. Expose an export filename helper preserving truthful detected format.

- [x] Write and run failing tests: disguised .jpg GIF remains image/gif/.gif; malformed GIF rejects; budget-compliant GIF transform0 and bytes identical, oversize animated GIF shrinks without flattening; wrong trusted digest rejects; static oversize output fails closed; real SDK encrypted vault ciphertext differs before fix and matches ADR-0060 prepared chat envelope after fix; existing collection duplicates upload once.
- [x] Implement minimal shared policy and route collection through existing prepared encryption, keeping metadata E2EE and upload=mime octet-stream. Compatibility tests for old random vault reads.
- [x] Focus tests/analyze, record commands/inputs/red-green under artifact task-1-report.md, commit owned files only; specification then security/quality review.

### Task 2: Integrate all client upload/read/export boundaries

Owner root: business_api_client.dart, gallery_media_payload.dart, group_announcement_service.dart, moment_image_preprocessor.dart, moment_composer_page.dart, moment_publish_coordinator.dart, moments_page.dart, avatar_source.dart, gallery_media_export.dart, encrypted_media_view.dart/wechat_image_editor.dart/wechat_video_message.dart, wallet_qr_exporter.dart/invite_code_page.dart, relevant tests; MomentMediaCache/RetainedImageCacheManager only for shared verified reads. DeviceGallerySource keeps original file selection; downstream shared preparation enforces upload budget. No matrix_e2ee_client/core policy edits while child owns them.

- [x] Audit complete upload/read/export inventory into artifact coverage.md before claiming completeness; use existing aggregate transport methods so ordinary files/voice/videos and avatar/cover/comment/poster are covered.
- [x] RED for GIF preprocessor direct call and disguised export; integrate shared image policy to avoid bypass through old standalone Moments routes; truthful export filename and shared original loader. Add byte/MIME validation at business PUT boundaries without changing session declaration or authorizations.
- [x] Shared read verification wraps existing authorized/cache loaders; it must not initiate unauthenticated requests or treat mxc hashes as authorization. Verify original-versus-preview precedence, account revoke and old cache behavior.
- [x] Run focused regressions, update coverage checklist and owned report; commit; independent specification and quality/security review.

### Task 3: End-to-end identity and whole candidate gates

Owner root/tests/docs. No runtime change without new focused red/green.

- [x] Initial GIF→compression→vault→chatA→chatB→export→Moments byte identity test; output meets agreed KB budget, subsequent GIF codec calls0, one deterministic ciphertext identity, distinct business domain retained. NonGIF intentional transformation gets new identity.
- [x] Complete focused tests, flutter analyze, final shared Flutter full tests and mobile contracts; preflight verify.ps1 and record actual missing environment rather than copy production secrets. No repeat on unchanged inputs.
- [x] Whole-branch domain/spec then quality/security review; update task/verification evidence. Source freeze only after gates/reviews.

### Task 4: Delivery

- [x] Read actual current production version/occupied CI versions. Reserve next Android/iOS version/build, update version contracts, freeze source/inputs.
- [x] Conventional Android rebuild/alignment/stable signer verification and authorized publication/update notes using existing lightweight gates; iOS native CI/signed candidate verified for enterprise-resign handoff. Preserve previous2195 package and both platform settings isolation.
- [ ] Merge/push reviewed download/doc backfill; complete artifact preservation and own worktree/branch cleanup. Return actual release links and iOS candidate; maintain iOS suspended discovery and device-only acceptance gaps.
