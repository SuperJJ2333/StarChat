# Moments response media cache identity

This additive read-response contract is compatible with the deployed 596601638c3aa0de228942b3b9001cddb0476dfc implementation. Existing OpenAPI request models remain unchanged (`additionalProperties: false`); never include these fields in create, preferences PUT, or cover PUT bodies. No new endpoint or schema migration.

| Read projection | Optional field | Value |
| --- | --- | --- |
| Moment DTO in feed/detail/search/personal timeline/create response | `image_cache_keys` | List aligned with `image_urls`; each entry is lowercase SHA-256 hex of the exact persisted original URL, or null for an absent reference. |
| Preferences GET/PUT response and cover PUT response | `cover_cache_key` | Lowercase SHA-256 hex of `cover_object_key`, falling back to persisted original `cover_url`; null when no cover. |

The server hashes stored references, not freshly signed fetch URLs. Re-signing changes the opaque token/path but preserves the digest. The existing server can hash external references as well; a digest alone does not establish trust or authorize content access.

The mobile client accepts a stable digest only with a verified account namespace, exactly 64 lowercase hex characters, an HTTP(S) URL without userinfo, an origin exactly equal to its configured Business API origin, and an exact `/api/v1/profile/avatar/content/<single-segment>` path. It derives the actual cache key from SHA256(JSON([URL origin, account namespace, server digest])), using UTF-8 and a versioned prefix. The complete URL is passed unchanged to the network provider. Neither tokens nor URL query/path components are decoded or stripped to infer identity. Fields that are missing/malformed, arrays whose length differs from image_urls, foreign paths/origins, or missing account identity use the existing full-URL cache behavior. Existing clients ignore the additive response fields.

Successful upload completion makes that upload/object immutable. Repeated completion returns COMPLETED; content PUT on it returns HTTP 409 with `MOMENT_MEDIA_COMPLETED`. put_content and complete acquire the upload row with SELECT FOR UPDATE, keeping their state and storage operations serialized on PostgreSQL. Changing an image/cover requires a new upload/object identity. No overwrite of an already completed object is supported. The normal persisted-original-reference change therefore generates a different stable key. Existing mutable external URLs are never folded into this stable-key namespace.

A cache identity is not a bearer grant, expiry extension, or a substitute for the existing page/session gate. Disk caching continues to use the existing 200-entry, seven-day staleness policy, not a guaranteed deletion deadline. Legacy URL-only disk entries age out normally.

Deployment: production already supplies the fields and has unrelated newer service behavior. Apply only the reviewed media.py immutable-upload patch there; do not replace production service.py with this checkout's narrower version. This checkout synchronizes only the read-field contract for consistent future source builds.
