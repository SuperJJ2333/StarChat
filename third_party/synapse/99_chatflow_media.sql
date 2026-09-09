-- Additive Synapse 1.132.0 schema, applied by the normal delta migration runner.
CREATE TABLE chatflow_media_blobs (
    digest TEXT PRIMARY KEY,
    media_id TEXT NOT NULL UNIQUE,
    unreferenced_ts BIGINT,
    retiring INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE chatflow_media_references (
    media_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    created_ts BIGINT NOT NULL,
    last_uploaded_ts BIGINT NOT NULL,
    deleted_ts BIGINT,
    media_type TEXT NOT NULL,
    upload_name TEXT,
    media_length BIGINT NOT NULL,
    PRIMARY KEY (media_id, user_id)
);
CREATE INDEX chatflow_media_references_user_idx
    ON chatflow_media_references (user_id, deleted_ts);
-- Intent is durable before bytes are stored. A crash/failing compensation
-- cannot expose an unpublished upload through the legacy fallback view.
CREATE TABLE chatflow_media_pending (
    digest TEXT PRIMARY KEY,
    media_id TEXT NOT NULL UNIQUE
);

-- Never resurrect the original uploader after its reference is deleted.
CREATE VIEW chatflow_media_user_view AS
SELECT m.media_id, r.media_type, r.media_length, r.upload_name,
       r.created_ts, m.url_cache, m.last_access_ts, m.quarantined_by,
       m.safe_from_quarantine, r.user_id, m.authenticated, m.sha256
FROM local_media_repository m
JOIN chatflow_media_blobs b ON b.media_id = m.media_id
JOIN chatflow_media_references r ON r.media_id = m.media_id
WHERE r.deleted_ts IS NULL
UNION ALL
SELECT m.media_id, m.media_type, m.media_length, m.upload_name,
       m.created_ts, m.url_cache, m.last_access_ts, m.quarantined_by,
       m.safe_from_quarantine, m.user_id, m.authenticated, m.sha256
FROM local_media_repository m
WHERE NOT EXISTS (SELECT 1 FROM chatflow_media_blobs b WHERE b.media_id = m.media_id)
AND NOT EXISTS (SELECT 1 FROM chatflow_media_pending p WHERE p.media_id = m.media_id);
