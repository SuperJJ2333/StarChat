# 2083 Moments comment authorization

Scope: approved `docs/superpowers/plans/2026-09-10-four-fixes-2083.md`; business API Moments module only. Product modernization specification read. There is no deeper business-api AGENTS.md in this checkout.

## Root cause and baseline

The existing local `reaction_audience` already prevented A from seeing B's comments by C (only B's friend) or E (stranger). The new five-account API test passed before implementation across feed, search, personal timeline, profile preview, cursor pages, and guessed hidden reply targets. This distinguishes the reported phone symptom from a demonstrated local baseline failure: stale deployed code or cached feed metadata must be checked by the root delivery task.

Two independent server gaps were reproduced before editing production code:

- Comment notifications checked post visibility only, returning C/E identity projections and counting their comment notifications as unread.
- Comments checked only the viewer's live relationships. After D ceased being B's friend, A still received D's historical comments because A/D remained friends.

Red evidence: `artifacts/2026-09-10/four-fixes-2083/comments/red.txt`, 2 failed / 1 passed, with assertions specifically showing the forbidden user IDs.

## Change

`moment_comment_audience` reuses the existing batched privacy policy. Foreign viewers receive comments from the intersection of viewer and post-author eligible reaction audiences, plus the viewer and post author. Owners retain the existing policy. Feed/detail/search/profile/pagination share DTO projection. Reply validation, reply parent projection (including idempotent retries), comment-notification identities/unread count, and saved comment-image capabilities now use the same comment audience.

Scope correction after review: likes keep the original viewer-relative `reaction_audience`; LIKE notifications keep the original post-visibility policy. This task changes comments only. A former author-friend's like can therefore remain visible when their comment is hidden, matching pre-existing like behavior. The initial implementation applied the common audience too broadly; `scope-red.txt` records two regression failures before restoring the original like/LIKE-notification semantics.

No schema, API shape, financial state, authentication, or signing changes. Relationship membership is evaluated in each new request/session. Images previously signed for a now-hidden commenter are denied on the subsequent server fetch.

## Reviews and validation

Specification review: A/B/C/D/E read paths, own post behavior, safe reply targets, current relationship revocation, and idempotent reply projection covered by API regression tests. Existing reaction tests cover blocks, directional contact privacy, exclusions, and disabled profile entry; author-friend removal now also covers saved media revocation.

Quality/security review: comment filtering precedes comment identity/avatar/body projection and comment counts; the shared relationship cache remains session-local. No client-side hiding is relied upon. Existing query-budget regression remains part of the focused suite. Likes and LIKE notifications are intentionally outside this change.

Focused verification (PowerShell 7, UTF-8, `PYTHONPATH=services/business-api`):

- `py -3.12 -m pytest tests/business_api/moments -q`: **90 passed**, 404.78 seconds. Evidence: `artifacts/2026-09-10/four-fixes-2083/comments/green.txt`.
- The author-removal media parameter was added after that run had collected its cases, so it was verified separately: `py -3.12 -m pytest tests/business_api/moments/test_reaction_privacy.py -k author_removed -q`: **1 passed, 9 deselected**, 10.93 seconds. Evidence: `artifacts/2026-09-10/four-fixes-2083/comments/author-media-green.txt`.
- Those results cover the initial broader implementation. After the scope correction: `py -3.12 -m pytest tests/business_api/moments/test_comment_audience_2083.py tests/business_api/moments/test_reaction_privacy.py -q`: **14 passed**, 88.52 seconds. Evidence: `artifacts/2026-09-10/four-fixes-2083/comments/scope-green.txt`. This verifies comment privacy, reply retries, saved comment images, query budget, and original like/LIKE-notification behavior against the final source. Full repository verification is assigned to root.

## Delivery requirements

Deploy `service.py`, `visibility.py`, and `media_access.py` together and restart the business API. No migration is required. APK installation alone cannot change server authorization. Root handles deployment and full repository checks.

Version the mobile feed/detail metadata cache namespace so old comment/name/avatar/reply projections are not rendered after upgrade; preserve the separate image cache. The backend has no persistent response cache in these paths. This subtask does not alter local caches or production services.
