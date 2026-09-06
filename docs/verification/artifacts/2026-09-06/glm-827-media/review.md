# 827db32 media focused review

Read-only production review; source HEAD 827db3267428eeb7f8353577956e5f8bf591d813. No APK/device test.

## P1 Video cache is still unused
room_page.dart:207 declares late final videoPosterCache but no production references read it, so Dart lazy initializer does not run. Both real video branches (2025,2206) call _loadVideoPoster (976), which still uses page-scoped thumbnailMemoryCache with 48-entry/64MiB LRU (media_cache.dart:224). Re-entering the room loses that instance; no poster disk cache in this path. Room declaration does not inject diskListKeys either (208-220).

## P1 GIF thumbnails remain JPEG/static
room_page.dart:2237-2238 returns any available thumbnail, with no MIME/content-format bypass for GIF originals. Thumbnail creation called at room_page.dart:867,1037 uses media_thumbnail.dart:39 CompressFormat.jpeg. Therefore an animated image with that valid JPEG thumbnail remains static in the bubble even though contain geometry is now correctly wired in the actual image branch at 2222. Do not infer full image viewer animation failure from this: original bytes may animate there.

## P2 Misdescribed disk backend / incomplete integration
The unused new callbacks call MediaCache.store directly (room_page.dart:214). This writes raw bytes at media_cache.dart:126; no encryption. Global LRU is enforced after writes at :145. This backend does not meet encrypted session disk/no-LRU contract and must be changed before wiring. Since the field is unused, this review does not claim newly exercised plaintext storage through that field. Session/account invalidation also absent. diskListKeys is not injected; no evidence of misdeleting all other room attachments because enumeration is absent.

## P2 clear/evict I/O races persist
Repro: dart docs/verification/artifacts/2026-09-06/glm-827-media/cache_races.dart

Output:
clear during diskWrite: expected disk empty=true actual=false; expected stale=true actual=false
evict during diskRead: expected stale=true actual=false; bytes still returned=true

video_poster_session_cache.dart:128 awaits diskWrite after its last generation check (121). clearAll can finish, then pending diskWrite persists deleted data; :134 reports non-stale success. Cached reads at :100 prevent memory write on invalidation but :103 return non-stale bytes anyway. Existing six regressions don't exercise this timing. Proper fix needs serialization/versioned disk writes and stale result enforcement, not only an earlier generation check.

## Confirmed partial improvement
Actual image branch now uses ContainImageBubble and opens full viewer via existing forwarding helper. No production edits made. Repro sources only under this artifact directory.
