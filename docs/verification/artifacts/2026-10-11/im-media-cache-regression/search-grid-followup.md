# Search-grid cache-reuse fixture after actual initial decoding

Input: root's frozen 5988deb48185f4f2fb0743615f17ccea597671ce. Its completed shared Flutter run recorded 5957 PASS / 9 skipped / 1 FAIL; the sole failure was room_search_media_grid_test.dart line 436, thumbnail HTTP count expected 1 but observed 2. This follow-up does not reclassify that full run as passing.

## Diagnosis

The original file was reproduced unchanged on the prior isolated 76678477 implementation, then again at exact 5988 with only the existing SEARCH_MEDIA_SCENARIO selector set to `current image`. The isolated managed checkout was reused on branch codex/im-search-grid-regression; root's W: drive and running checkout were never modified. The first scenario has two current messages with the same authenticated thumbnail descriptor.

Temporary synthetic-only instrumentation demonstrated this exact order:

1. The neighbor creates the source flight; the old/current message joins it (`existing=true`). Only HTTP request 1 starts.
2. Worker integrity verification and store-root preparation finish. The object operation has started; its existing-object/index lookup and cold quota readiness have not yet reached the `quota ready` diagnostic boundary. The trace does not separately time those two awaits.
3. The test's fixed `_settle` interval returns and the test taps details. Both initial bubbles leave visibility. Their shared source becomes inactive before real settlement.
4. Quota initialization finishes. The publication guard correctly rejects the now-unobserved write. No completed thumbnail cache exists.
5. The search-grid consumer starts later and correctly performs HTTP request 2.

Thus the first pair already shares one download. The test incorrectly treated a fixed pump interval as proof that initial cache publication completed before hiding all consumers. Allowing step 4 to publish would undo the independently verified cancellation contract. The two requests are not simultaneous duplicate work for the two current messages. This report does not infer a device latency target from the widget fake-async cold database timing.

## Minimal test correction

Only room_search_media_grid_test.dart changes: before navigating away in `current image`, wait at most 100 real-I/O/pump iterations for both ContainImageBubble descendants to decode. Assert both decoded images and exactly one thumbnail download at this boundary. Then retain the original later assertion of exactly one thumbnail download after the search tile decodes. No expected count changes to 2, no additional network call is ignored, and all existing current-window, foreign-account, hidden/revoked/disposed, lazy-grid and gallery checks remain.

The temporary diagnostics are removed from runtime/test code and retained only as search-grid-diagnostic.patch plus logs for reproducibility. git diff against 5988 for apps/mobile_flutter/lib is empty. No cache, Matrix, RoomPage, native, dependency, APK or distribution behavior changes. The already running iOS same-runtime-source build is not claimed as validated here.

## Evidence

- search-grid-baseline.log: original complete file on 76678477, fails first/current-image scenario at the exact original assertion.
- search-grid-root-red.log: unchanged test on exact 5988 with current-image selection, same failure.
- search-grid-diagnostic.log and search-grid-timing.log: temporary instrumentation identifies shared first work, pre-publication cancellation, and later second request. The latter includes the exact test navigation and quota-ready ordering.
- search-grid-current-green.log: final test correction, selected current-image scenario, PASS with both pre-navigation and post-search download counts equal to 1.
- search-grid-impact.log and search-grid-impact-timing.json: final five-file run covers the entire ten-scenario file, search context/visibility, image preview cache and bubble lifecycle: 29 PASS, exit 0, in one run.
- search-grid-analyze.log: final changed test file, zero issues, exit 0.
- search-grid-input-identities.json: frozen input base, final source/test and evidence hashes, raw/LF identities and executable commands.

The selected scenario and full-file run overlap and are not summed as unique cases. Each ten-scenario widget loop is one Flutter test, not ten separately counted tests. Parent owns independent review and the shared-gate evidence reconciliation; no repeated source build, deployment or platform acceptance is claimed. Revert this test-only follow-up to restore the original failing fixture. Production sources remain exactly those at 5988.
