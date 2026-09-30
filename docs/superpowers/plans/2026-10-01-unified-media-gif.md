# Unified media and GIF fidelity implementation plan

> **For agentic workers:** Use subagent-driven-development task-by-task; one implementation child at a time, root may own independent integration files. User has preapproved plans/ADRs/autonomous execution. Temporary skill artifacts are placed in docs/verification/artifacts/2026-10-01/unified-media/, overriding .superpowers defaults.

**Goal:** One shared media policy for ingestion, preserved originals, verified reads and format-correct exports; unchanged GIFs remain identical across collection/re-send/forward/save/Moments.
**Architecture:** Shared client MediaAssetGateway with existing Matrix and business transport/cache adapters. Keep encrypted chat and business media storage and authorization domains separate.
**Tech Stack:** Flutter3.44.9/Dart3.12.2, vendored Matrix, existing Android/iOS gallery APIs and business API.
**Spec:** ../specs/2026-10-01-unified-media-gif-design.md

## Global constraints

GIF20MiB/4Mi canvas pixels/128Mi cumulative decoded pixels; current caches and scheduling budgets unchanged. No global bytes/Future cache; no recovery/room keys, plaintext attachment or plaintext hash to business/push/logs. ADR-0060 algorithm unchanged, no cross-user plaintext dedup. Preserve old capabilities, mxc and storage paths; no destructive migrations. No shared file concurrent editing. Keep other main WIP. Releases require fresh version reservation and stable signer.

## Review focus

Disguised GIF headers; corrupt/truncated animation; export of loaded thumbnail instead of original; MIME/length mismatch after begin; stale account/lease across async reads. Test real GIF bytes and observable codec/transport calls, not only source strings.

### Task 1: Shared original policy and encrypted collection

Owner child: create lib/features/media/media_asset_gateway.dart and relevant tests; matrix_e2ee_client.dart ONLY uploadEncrypted vault method/import; content_addressed_media.dart as required for real shared Matrix prepared exit; matrix_emoji_vault/emoji_vault tests. No other regions of matrix_e2ee_client or Moments/UI files.

Interfaces: expose MediaAssetGateway.inspect(Uint8List bytes,{required String mimeType,required String filename}) returning bytes/mimeType/filename and isGif; prepareImage(bytes,{required Future<Uint8List> Function(Uint8List) transform}) returns original validated GIF without transform and delegates other input; readOriginal(loader,{String? expectedSha256}) verifies supplied trusted digest without permanent caching. Expose an export filename helper preserving truthful detected format. Refine API in report before dependent tasks; root uses these exact public methods.

- [ ] Write and run failing tests: disguised .jpg GIF remains image/gif/.gif; malformed GIF rejects; GIF transform0 and bytes identical; wrong trusted digest rejects; nonGIF processing works; real SDK encrypted vault ciphertext differs before fix and matches ADR-0060 prepared chat envelope after fix; existing collection duplicates upload once.
- [ ] Implement minimal shared policy and route collection through existing prepared encryption, keeping metadata E2EE and upload=mime octet-stream. Compatibility tests for old random vault reads.
- [ ] Focus tests/analyze, record commands/inputs/red-green under artifact task-1-report.md, commit owned files only; specification then security/quality review.

### Task 2: Integrate all client upload/read/export boundaries

Owner root: business_api_client.dart, device_gallery_source.dart, moment_image_preprocessor.dart, moment_composer_page.dart, moment_publish_coordinator.dart, ui/chat/encrypted_media_view.dart and wechat_image_editor.dart, relevant tests; cache/protocol base readers only where needed for shared verified reads. One later child may own a declared independent subset after Task1 finishes.

- [ ] Audit complete upload/read/export inventory into artifact coverage.md before claiming completeness; use existing aggregate transport methods so ordinary files/voice/videos and avatar/cover/comment/poster are covered.
- [ ] RED for GIF preprocessor direct call and disguised export; integrate shared image policy to avoid bypass through old standalone Moments routes; truthful export filename and shared original loader. Add byte/MIME validation at business PUT boundaries without changing session declaration or authorizations.
- [ ] Shared read verification wraps existing authorized/cache loaders; it must not initiate unauthenticated requests or treat mxc hashes as authorization. Verify original-versus-preview precedence, account revoke and old cache behavior.
- [ ] Run focused regressions, update coverage checklist and owned report; commit; independent specification and quality/security review.

### Task 3: End-to-end identity and whole candidate gates

Owner root/tests/docs. No runtime change without new focused red/green.

- [ ] C→vault→chatA→chatB→export→Moments byte identity test; zero GIF original codec calls, one deterministic ciphertext identity, distinct business domain retained. NonGIF intentional transformation gets new identity.
- [ ] Complete focused tests, flutter analyze, final shared Flutter full tests and mobile contracts; preflight verify.ps1 and record actual missing environment rather than copy production secrets. No repeat on unchanged inputs.
- [ ] Whole-branch domain/spec then quality/security review; update task/verification evidence. Source freeze only after gates/reviews.

### Task 4: Delivery

- [ ] Read actual current production version/occupied CI versions. Reserve next Android/iOS version/build, update version contracts, freeze source/inputs.
- [ ] Conventional Android rebuild/alignment/stable signer verification and authorized publication/update notes using existing lightweight gates; iOS native CI/signed candidate and enterprise-resign handoff. Preserve previous 2195 package and both platform settings isolation.
- [ ] Merge/push main; preserve all named artifacts before only own worktree/branch cleanup. Return actual release links and iOS candidate; maintain iOS suspended discovery and device-only acceptance gaps.
