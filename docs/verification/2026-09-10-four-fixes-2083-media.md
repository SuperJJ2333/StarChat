# Moments media: 2083 verification

Approved plan: `docs/superpowers/plans/2026-09-10-four-fixes-2083.md`.

Changes owned: `moment_media_cache.dart`, `wechat_moment_image_grid.dart`, `moment_image_viewer_page.dart`, the feed sliver section of `moments_page.dart`, and three focused test files. No business API, account-cache repository, authorization, URL-signature, or encryption changes.

## Findings and policy

The existing disk-backed provider already reuses a successful download when its stable identity is present. Actual HTTP tests confirm this; a blanket cache rewrite was unnecessary. Rotating signed URLs require the existing trusted server digest. Missing digests intentionally use the complete URL, so distinct signed URLs without a digest must remain distinct. Production response identity availability needs deployment-level verification; these tests do not establish the state of the running server.

Trusted immutable identity remains the SHA-256-derived account + exact API origin + server digest key, accepted only for the existing trusted avatar-content endpoint contract. Fallback keys now hash account + complete URL, fixing cross-account sharing without stripping any signature/query/path component. Unauthenticated callers retain exact-URL identity.

Decoded frames reuse Flutter's bounded image cache. The existing disk cache retains 200 entries with seven-day idle cleanup; HTTP freshness/expiry and stale-on-refresh-failure behavior remain supplied by the existing retained manager. This is scheduled cache-manager cleanup, not a synchronous hard byte limit. Failed explicit retries remove only the failed key before refetching, permitting recovery from a corrupt disk image. Successful cached data is never cleared on feed navigation.

The HTTP service permits at most three concurrent media downloads (previously ten). Feed posts now use SliverList.builder and a half-viewport scroll cache region on either side; near-viewport rendering provides bounded prefetch without a whole-feed precache loop. Existing image geometry is preserved, with a same-cell placeholder and accessible explicit retry in both grid and full-screen viewer.

## Test-first evidence

Observed initial failures, before corresponding implementation:

- Alice and Bob fallback providers compared equal for the same URL.
- Real HTTP batch peak was 10, failing the <=3 bound.
- Grid and then full-screen viewer had no accessible retry action.
- Removing only the decoded error retained corrupt disk bytes: retry request count was 0, failing expected 1. Removing the failed disk entry fixed actual recovery.
- Feed had no explicit viewport-relative prefetch extent (null rather than the half-viewport policy).

Actual local HTTP lifecycle counts: first successful load 1; immediate disk revisit still 1; expired refresh 2; expired/offline refresh 3 while a usable disk FileInfo remains; cold failure plus successful retry total 5; twelve new parallel URLs total 17 with peak <=3. The existing signed-rotation test also proves a decoded memory identity hit, evicts decoded memory, and then resolves a refreshed signed URL from disk without a second HTTP request. Changed trusted content digest causes exactly one new request.

Both grid and viewer start with corrupt disk data, expose retry, fetch exactly one successful replacement, paint a decoded RawImage, and retain identical bounds across loading/error/success.

Focused verification: 34 tests passed across media lifecycle/cache/stable identity/retained manager, moments flow, account identity refresh and privacy refresh suites. Transcript: `artifacts/2026-09-10/four-fixes-2083/media/focused-green.txt`. Focused analyzer transcript: `artifacts/2026-09-10/four-fixes-2083/media/analyze-green.txt`.

Specification review: stable trusted identity and URL fallback retained; account isolation strengthened; memory/disk reuse, bounded near-viewport work, retry, stable placeholders and existing TTL/cleanup covered. Quality/security review: no server permission/cache bypass, no signature stripping, no secrets or private payload logging, no shared cache-repository edits. Root owns full integration checks and device delivery.
