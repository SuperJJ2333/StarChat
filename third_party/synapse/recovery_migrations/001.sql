CREATE TABLE chatflow_recovery_accounts (
 owner TEXT PRIMARY KEY, active_version TEXT, revision BIGINT NOT NULL DEFAULT 0,
 stored_bytes BIGINT NOT NULL DEFAULT 0 CHECK(stored_bytes >= 0),
 candidate_count BIGINT NOT NULL DEFAULT 0 CHECK(candidate_count >= 0)
);
CREATE TABLE chatflow_recovery_versions (
 owner TEXT NOT NULL REFERENCES chatflow_recovery_accounts(owner), version TEXT NOT NULL,
 envelope TEXT NOT NULL, envelope_revision BIGINT NOT NULL DEFAULT 1,
 PRIMARY KEY(owner, version), UNIQUE(version)
);
ALTER TABLE chatflow_recovery_accounts ADD CONSTRAINT chatflow_recovery_active_fk
 FOREIGN KEY(owner, active_version) REFERENCES chatflow_recovery_versions(owner, version);
CREATE TABLE chatflow_recovery_heads (
 owner TEXT NOT NULL, version TEXT NOT NULL, room_id TEXT NOT NULL, session_id TEXT NOT NULL,
 revision BIGINT NOT NULL, best_digest TEXT NOT NULL,
 PRIMARY KEY(owner, version, room_id, session_id),
 FOREIGN KEY(owner, version) REFERENCES chatflow_recovery_versions(owner, version)
);
CREATE TABLE chatflow_recovery_sessions (
 owner TEXT NOT NULL, version TEXT NOT NULL, room_id TEXT NOT NULL, session_id TEXT NOT NULL,
 digest TEXT NOT NULL, candidate_revision BIGINT NOT NULL,
 first_message_index BIGINT NOT NULL, forwarded_count INTEGER NOT NULL,
 candidate TEXT NOT NULL,
 PRIMARY KEY(owner, version, room_id, session_id, digest),
 UNIQUE(owner, version, room_id, session_id, candidate_revision),
 FOREIGN KEY(owner, version) REFERENCES chatflow_recovery_versions(owner, version)
);
CREATE INDEX chatflow_recovery_candidates_order ON chatflow_recovery_sessions
 (owner, version, room_id, session_id, first_message_index, forwarded_count, digest);
CREATE TABLE chatflow_recovery_operations (
 owner TEXT NOT NULL, operation_id TEXT NOT NULL, request_digest TEXT NOT NULL,
 receipt TEXT NOT NULL, PRIMARY KEY(owner, operation_id),
 FOREIGN KEY(owner) REFERENCES chatflow_recovery_accounts(owner)
);
CREATE TABLE chatflow_recovery_audit (
 id BIGSERIAL PRIMARY KEY, owner TEXT NOT NULL, version TEXT NOT NULL,
 actor_device TEXT NOT NULL, authority_generation BIGINT NOT NULL,
 operation_id TEXT, action TEXT NOT NULL, occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
