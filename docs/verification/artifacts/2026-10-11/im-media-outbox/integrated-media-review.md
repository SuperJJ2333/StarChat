# Integrated media test correction: independent review

Reviewed the unstaged three-file delta against `9902d35079e9cb051125808a251ae479b06893cb` in `im-media-outbox/StarChat`. Reviewer: `media_identity_review`, 2026-10-11. Scope is two test corrections and the adjacent Matrix API comment; no executable production change is present. Source inspection was read-only. The only reviewer-written artifact is this report. No reviewer test rerun was requested or performed.

## Specification and domain review — PASS

The former `owned media bytes and thumbnails preserve Uint8List identity` test supplied ordinary mutable arrays, not registered owned snapshots. Its first failing assertion is factory-test line 2457 in the RED input. The real send path invokes `prepareContentAddressedMedia` and `cacheOutgoingMedia`, whose `VerifiedMediaContent.verify` returns a worker-owned immutable snapshot. Only a private registered proof in the same account/global/account epoch permits proof reuse. Cache content interning may return an existing canonical instance. Requiring identity with the original mutable array contradicts those boundaries; restoring that identity in production would weaken alias safety.

The replacement assertions require unchanged payload/thumbnail/GIF content, different identity from mutable inputs, stability after producer mutation, and rejected mutation of returned snapshots (including the thumbnail buffer view). This is consistent with the existing R7b proof tests, including same-scope proof reuse, false-digest rejection, epoch separation and immutable buffer aliases. The corrected API comment accurately separates avoiding duplicate entry copies from establishing the trusted snapshot later. No new claim of zero allocation or universal owned-input identity is made.

The forwarding test retains the real RoomPage action, encrypted download, source-lease revocation and owner drain. Its target SDK double now signals actual send entry and holds its returned Future with an explicit settlement completer. The test waits for send entry, verifies that drain remains pending after source closure and two seconds of pumped fake time, then releases the actual SDK Future and awaits drain. This preserves and strengthens the relevant domain assertion: closing the source UI/lease does not release accepted owner work before transport settlement. Production scheduler/admission/timeout behavior is unchanged.

## Quality and security review — PASS

Reviewed after the specification/domain pass. No blocking finding in the three-file delta. The new milestone helper interleaves real worker/file I/O with Flutter FakeAsync pumping; it observes the supplied Future, captures and rethrows errors, and requires settlement. Its 30-second wall-clock watchdog fails the test without completing the operation, releasing its owner, or manufacturing success. The target gate is completed explicitly only after assertions that drain is still pending and no send result has been recorded. The successful path still requires exactly one completed target send and no framework exception. No ignored test, dropped invariant, production timeout, allocation bypass, encryption change, account-boundary change, or secret logging was introduced.

Evidence inspected:

- `integrated-media-red.txt`: two-file original run, 82 pass / 1 fail; raw input identity fails at factory line 2457. The UI case passes in this run.
- `integrated-forward-deadline-red.patch` and `.txt`: the old fixed iteration drain oracle fails when the target real Future is held for 1500 ms. This demonstrates a brittle test deadline; it does not by itself reconstruct the exact timing of the earlier full-suite failure.
- `integrated-media-fakeasync-attempt.txt`: unsuccessful direct runAsync-wait attempt is retained, with 30-second timeouts. It is not a product RED or a passing gate.
- `integrated-media-green.txt`: both complete files finish with `+83: All tests passed!`; implementer reported exit 0. This is inspected implementer evidence, not an independent rerun.
- Reviewer `git diff --check` on the three files: passed with no output.

Three-file analysis and adjacent proof/forward regressions were still being run by the implementer when this review was written. This review does not claim those gates, the full Flutter suite, native execution, packaging or device acceptance passed.

## Exact reviewed identities

SHA-256 of working-tree bytes:

| Input | SHA-256 |
| --- | --- |
| `apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart` | `40f57796add2aedcd3b3ad12531b2ca321b18e2f8d699bf0ab46012f1b8c03be` |
| `apps/mobile_flutter/test/features/matrix/matrix_client_factory_test.dart` | `4df5dc23eb7e1d3385aa44f202830ea0da3ed7fff5387a1c63ee554a5973fea8` |
| `apps/mobile_flutter/test/features/matrix/matrix_room_media_ui_test.dart` | `5c63d666387a03628500d1bf09f243b654b4b46ae117271e8403c91e6e700bdc` |
| `integrated-media-red.txt` | `044dcce500b0eae037131c25d584796f130fddc7420ae42923242150cd584a2b` |
| `integrated-media-green.txt` | `eb003cc7b378be31423b8418995cc2d45ef701eb7cc45a53486ed2556b1ec121` |
| `integrated-forward-deadline-red.txt` | `75a832833a80c08cef15d0ca2c42e8ba2e18ad0b5cd4146e30299864e9fd4f2e` |
| `integrated-forward-deadline-red.patch` | `f377b56d9197dfa10d4cd230c31b4c084290899f791118b99b7c7d719b544f27` |
| `integrated-media-fakeasync-attempt.txt` | `f74edd562f6a8c70742dad9af8834ddb70831ac3305aa23b83d8cbf6c19d5782` |
