BEGIN;

CREATE TABLE alembic_version (
    version_num VARCHAR(32) NOT NULL, 
    CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
);

-- Running upgrade  -> 0001_foundation

INSERT INTO alembic_version (version_num) VALUES ('0001_foundation') RETURNING alembic_version.version_num;

-- Running upgrade 0001_foundation -> 0002_idempotency_records

CREATE TABLE idempotency_records (
    id VARCHAR(36) NOT NULL, 
    scope VARCHAR(100) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    request_hash VARCHAR(128) NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    response_status INTEGER, 
    response_body JSON, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    completed_at TIMESTAMP WITH TIME ZONE, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_idempotency_scope_key UNIQUE (scope, idempotency_key)
);

UPDATE alembic_version SET version_num='0002_idempotency_records' WHERE alembic_version.version_num = '0001_foundation';

-- Running upgrade 0002_idempotency_records -> 0003_outbox_events

CREATE TABLE outbox_events (
    id VARCHAR(36) NOT NULL, 
    topic VARCHAR(100) NOT NULL, 
    event_type VARCHAR(100) NOT NULL, 
    aggregate_type VARCHAR(100) NOT NULL, 
    aggregate_id VARCHAR(128) NOT NULL, 
    payload JSON NOT NULL, 
    event_headers JSON NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    attempt_count INTEGER NOT NULL, 
    available_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    locked_at TIMESTAMP WITH TIME ZONE, 
    locked_by VARCHAR(100), 
    last_error TEXT, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    published_at TIMESTAMP WITH TIME ZONE, 
    PRIMARY KEY (id)
);

CREATE INDEX ix_outbox_claim ON outbox_events (status, available_at, created_at);

UPDATE alembic_version SET version_num='0003_outbox_events' WHERE alembic_version.version_num = '0002_idempotency_records';

-- Running upgrade 0003_outbox_events -> 0004_identity_foundation

CREATE TYPE accountstatus AS ENUM ('PENDING_EMAIL', 'PENDING_MATRIX', 'ACTIVE', 'SUSPENDED', 'DISABLED');

CREATE TABLE users (
    id VARCHAR(36) NOT NULL, 
    username VARCHAR(64) NOT NULL, 
    username_normalized VARCHAR(64) NOT NULL, 
    email VARCHAR(320) NOT NULL, 
    email_normalized VARCHAR(320) NOT NULL, 
    password_hash VARCHAR(512) NOT NULL, 
    status accountstatus NOT NULL, 
    matrix_user_id VARCHAR(255), 
    email_verified_at TIMESTAMP WITH TIME ZONE, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    UNIQUE (username_normalized), 
    UNIQUE (email_normalized), 
    UNIQUE (matrix_user_id)
);

CREATE TABLE invitations (
    id VARCHAR(36) NOT NULL, 
    code_hash VARCHAR(64) NOT NULL, 
    max_uses INTEGER NOT NULL, 
    use_count INTEGER NOT NULL, 
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    revoked_at TIMESTAMP WITH TIME ZONE, 
    created_by VARCHAR(36) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    UNIQUE (code_hash)
);

CREATE TABLE email_verification_challenges (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    token_hash VARCHAR(64) NOT NULL, 
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    consumed_at TIMESTAMP WITH TIME ZONE, 
    attempt_count INTEGER NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(user_id) REFERENCES users (id), 
    UNIQUE (token_hash)
);

CREATE INDEX ix_email_verification_challenges_user_id ON email_verification_challenges (user_id);

CREATE TABLE password_reset_challenges (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    token_hash VARCHAR(64) NOT NULL, 
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    consumed_at TIMESTAMP WITH TIME ZONE, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(user_id) REFERENCES users (id), 
    UNIQUE (token_hash)
);

CREATE INDEX ix_password_reset_challenges_user_id ON password_reset_challenges (user_id);

CREATE TABLE identity_devices (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    device_key VARCHAR(128) NOT NULL, 
    display_name VARCHAR(128) NOT NULL, 
    last_seen_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    revoked_at TIMESTAMP WITH TIME ZONE, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_device_user_key UNIQUE (user_id, device_key), 
    FOREIGN KEY(user_id) REFERENCES users (id)
);

CREATE INDEX ix_identity_devices_user_id ON identity_devices (user_id);

CREATE TABLE refresh_token_families (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    device_id VARCHAR(36) NOT NULL, 
    revoked_at TIMESTAMP WITH TIME ZONE, 
    revoke_reason VARCHAR(100), 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(user_id) REFERENCES users (id), 
    FOREIGN KEY(device_id) REFERENCES identity_devices (id)
);

CREATE INDEX ix_refresh_token_families_user_id ON refresh_token_families (user_id);

CREATE TABLE refresh_tokens (
    id VARCHAR(36) NOT NULL, 
    family_id VARCHAR(36) NOT NULL, 
    token_hash VARCHAR(64) NOT NULL, 
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    consumed_at TIMESTAMP WITH TIME ZONE, 
    replaced_by_id VARCHAR(36), 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(family_id) REFERENCES refresh_token_families (id), 
    UNIQUE (token_hash)
);

CREATE INDEX ix_refresh_tokens_family_id ON refresh_tokens (family_id);

CREATE TYPE rolecode AS ENUM ('USER', 'SUPPORT_AGENT', 'FINANCE_SUPPORT', 'SUPPORT_SUPERVISOR', 'SUPER_ADMIN');

CREATE TABLE user_roles (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    role_code rolecode NOT NULL, 
    assigned_by VARCHAR(36) NOT NULL, 
    assigned_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_user_role UNIQUE (user_id, role_code)
);

CREATE INDEX ix_user_roles_user_id ON user_roles (user_id);

CREATE TABLE totp_credentials (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    encrypted_secret VARCHAR(1024) NOT NULL, 
    enabled BOOLEAN NOT NULL, 
    last_accepted_step INTEGER, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    UNIQUE (user_id), 
    FOREIGN KEY(user_id) REFERENCES users (id)
);

CREATE TYPE holdtype AS ENUM ('WITHDRAWAL');

CREATE TABLE security_holds (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    hold_type holdtype NOT NULL, 
    reason_code VARCHAR(100) NOT NULL, 
    starts_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    ends_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(user_id) REFERENCES users (id)
);

CREATE INDEX ix_security_holds_user_id ON security_holds (user_id);

UPDATE alembic_version SET version_num='0004_identity_foundation' WHERE alembic_version.version_num = '0003_outbox_events';

-- Running upgrade 0004_identity_foundation -> 0005_audit_events

CREATE TABLE audit_events (
    id VARCHAR(36) NOT NULL, 
    actor_id VARCHAR(36), 
    subject_type VARCHAR(100) NOT NULL, 
    subject_id VARCHAR(128) NOT NULL, 
    action VARCHAR(150) NOT NULL, 
    result VARCHAR(30) NOT NULL, 
    reason_code VARCHAR(100) NOT NULL, 
    trace_id VARCHAR(128) NOT NULL, 
    source_ip VARCHAR(64), 
    source_device_id VARCHAR(36), 
    before_data JSON, 
    after_data JSON, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id)
);

CREATE INDEX ix_audit_events_actor_id ON audit_events (actor_id);

CREATE INDEX ix_audit_events_subject_id ON audit_events (subject_id);

CREATE INDEX ix_audit_events_action ON audit_events (action);

CREATE INDEX ix_audit_events_trace_id ON audit_events (trace_id);

CREATE FUNCTION reject_audit_event_mutation() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'audit_events is append-only';
        END;
        $$ LANGUAGE plpgsql;;

CREATE TRIGGER audit_events_append_only
        BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW EXECUTE FUNCTION reject_audit_event_mutation();;

UPDATE alembic_version SET version_num='0005_audit_events' WHERE alembic_version.version_num = '0004_identity_foundation';

-- Running upgrade 0005_audit_events -> 0006_support_queue

CREATE TABLE support_agent_presence (
    agent_id VARCHAR(36) NOT NULL, 
    online BOOLEAN NOT NULL, 
    active_tickets INTEGER NOT NULL, 
    skills JSON NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (agent_id)
);

CREATE TABLE support_tickets (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    room_id VARCHAR(255) NOT NULL, 
    skill VARCHAR(80) NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    assignee_id VARCHAR(36), 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id)
);

CREATE INDEX ix_support_tickets_user_id ON support_tickets (user_id);

CREATE INDEX ix_support_tickets_assignee_id ON support_tickets (assignee_id);

UPDATE alembic_version SET version_num='0006_support_queue' WHERE alembic_version.version_num = '0005_audit_events';

-- Running upgrade 0006_support_queue -> 0007_caibi_ledger

CREATE TABLE ledger_transactions (
    id VARCHAR(36) NOT NULL, 
    asset VARCHAR(16) NOT NULL, 
    scope VARCHAR(80) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    actor_id VARCHAR(36) NOT NULL, 
    reason_code VARCHAR(100) NOT NULL, 
    reversal_of_id VARCHAR(36), 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_ledger_scope_idempotency UNIQUE (scope, idempotency_key)
);

CREATE TABLE ledger_entries (
    id VARCHAR(36) NOT NULL, 
    transaction_id VARCHAR(36) NOT NULL, 
    account_id VARCHAR(64) NOT NULL, 
    asset VARCHAR(16) NOT NULL, 
    amount NUMERIC(20, 2) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(transaction_id) REFERENCES ledger_transactions (id)
);

CREATE INDEX ix_ledger_entries_transaction_id ON ledger_entries (transaction_id);

CREATE INDEX ix_ledger_entries_account_id ON ledger_entries (account_id);

CREATE TABLE adjustment_policies (
    actor_id VARCHAR(36) NOT NULL, 
    per_transaction NUMERIC(20, 2) NOT NULL, 
    per_day NUMERIC(20, 2) NOT NULL, 
    allowed_users JSON NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (actor_id)
);

CREATE TABLE adjustment_requests (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    amount NUMERIC(20, 2) NOT NULL, 
    reason_code VARCHAR(100) NOT NULL, 
    status VARCHAR(30) NOT NULL, 
    submitted_by VARCHAR(36) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    finance_reviewer_id VARCHAR(36), 
    admin_reviewer_id VARCHAR(36), 
    ledger_transaction_id VARCHAR(36), 
    business_date DATE NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_adjustment_submit_idempotency UNIQUE (submitted_by, idempotency_key)
);

CREATE INDEX ix_adjustment_requests_user_id ON adjustment_requests (user_id);

CREATE INDEX ix_adjustment_requests_submitted_by ON adjustment_requests (submitted_by);

CREATE FUNCTION reject_ledger_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'ledger is append-only'; END; $$ LANGUAGE plpgsql;

CREATE TRIGGER ledger_transactions_append_only BEFORE UPDATE OR DELETE ON ledger_transactions FOR EACH ROW EXECUTE FUNCTION reject_ledger_mutation();

CREATE TRIGGER ledger_entries_append_only BEFORE UPDATE OR DELETE ON ledger_entries FOR EACH ROW EXECUTE FUNCTION reject_ledger_mutation();

UPDATE alembic_version SET version_num='0007_caibi_ledger' WHERE alembic_version.version_num = '0006_support_queue';

-- Running upgrade 0007_caibi_ledger -> 0008_caibi_red_packets

CREATE TABLE red_packets (
    id VARCHAR(36) NOT NULL, 
    sender_id VARCHAR(36) NOT NULL, 
    total NUMERIC(20, 2) NOT NULL, 
    share_count INTEGER NOT NULL, 
    mode VARCHAR(16) NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    room_id VARCHAR(255), 
    recipient_id VARCHAR(36), 
    idempotency_key VARCHAR(128) NOT NULL, 
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_red_packet_create_idempotency UNIQUE (sender_id, idempotency_key)
);

CREATE INDEX ix_red_packets_sender_id ON red_packets (sender_id);

CREATE TABLE red_packet_shares (
    id VARCHAR(36) NOT NULL, 
    packet_id VARCHAR(36) NOT NULL, 
    ordinal INTEGER NOT NULL, 
    amount NUMERIC(20, 2) NOT NULL, 
    claimed_by VARCHAR(36), 
    claimed_at TIMESTAMP WITH TIME ZONE, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_red_packet_share_ordinal UNIQUE (packet_id, ordinal), 
    CONSTRAINT uq_red_packet_claimant UNIQUE (packet_id, claimed_by), 
    FOREIGN KEY(packet_id) REFERENCES red_packets (id)
);

CREATE INDEX ix_red_packet_shares_packet_id ON red_packet_shares (packet_id);

UPDATE alembic_version SET version_num='0008_caibi_red_packets' WHERE alembic_version.version_num = '0007_caibi_ledger';

-- Running upgrade 0008_caibi_red_packets -> 0009_red_packet_claims

CREATE TABLE red_packet_claims (
    id VARCHAR(36) NOT NULL, 
    packet_id VARCHAR(36) NOT NULL, 
    share_id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_red_packet_claim_user UNIQUE (packet_id, user_id), 
    CONSTRAINT uq_red_packet_claim_idempotency UNIQUE (packet_id, idempotency_key), 
    FOREIGN KEY(packet_id) REFERENCES red_packets (id), 
    UNIQUE (share_id), 
    FOREIGN KEY(share_id) REFERENCES red_packet_shares (id)
);

CREATE INDEX ix_red_packet_claims_packet_id ON red_packet_claims (packet_id);

UPDATE alembic_version SET version_num='0009_red_packet_claims' WHERE alembic_version.version_num = '0008_caibi_red_packets';

-- Running upgrade 0009_red_packet_claims -> 0010_usdt_wallet

CREATE TABLE wallet_ledger_transactions (
    id VARCHAR(36) NOT NULL, 
    asset VARCHAR(20) NOT NULL, 
    scope VARCHAR(80) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    actor_id VARCHAR(36) NOT NULL, 
    reason_code VARCHAR(100) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_wallet_ledger_idempotency UNIQUE (scope, idempotency_key)
);

CREATE TABLE wallet_ledger_entries (
    id VARCHAR(36) NOT NULL, 
    transaction_id VARCHAR(36) NOT NULL, 
    account_id VARCHAR(64) NOT NULL, 
    asset VARCHAR(20) NOT NULL, 
    amount NUMERIC(30, 6) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(transaction_id) REFERENCES wallet_ledger_transactions (id)
);

CREATE INDEX ix_wallet_ledger_entries_transaction_id ON wallet_ledger_entries (transaction_id);

CREATE INDEX ix_wallet_ledger_entries_account_id ON wallet_ledger_entries (account_id);

CREATE TABLE wallet_deposits (
    id VARCHAR(36) NOT NULL, 
    event_id VARCHAR(128) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    txid VARCHAR(128) NOT NULL, 
    amount NUMERIC(30, 6) NOT NULL, 
    confirmations INTEGER NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    UNIQUE (event_id), 
    UNIQUE (txid)
);

CREATE INDEX ix_wallet_deposits_user_id ON wallet_deposits (user_id);

CREATE TABLE wallet_withdrawals (
    id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    client_order_id VARCHAR(128) NOT NULL, 
    address VARCHAR(128) NOT NULL, 
    amount NUMERIC(30, 6) NOT NULL, 
    status VARCHAR(32) NOT NULL, 
    finance_approver_id VARCHAR(36), 
    admin_approver_id VARCHAR(36), 
    provider_txid VARCHAR(128), 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_wallet_withdrawal_order UNIQUE (user_id, client_order_id)
);

CREATE INDEX ix_wallet_withdrawals_user_id ON wallet_withdrawals (user_id);

CREATE TABLE wallet_controls (
    id VARCHAR(20) NOT NULL, 
    withdrawals_paused BOOLEAN NOT NULL, 
    pause_reason VARCHAR(255), 
    PRIMARY KEY (id)
);

CREATE FUNCTION reject_wallet_ledger_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'wallet ledger is append-only'; END; $$ LANGUAGE plpgsql;

CREATE TRIGGER wallet_ledger_transactions_append_only BEFORE UPDATE OR DELETE ON wallet_ledger_transactions FOR EACH ROW EXECUTE FUNCTION reject_wallet_ledger_mutation();

CREATE TRIGGER wallet_ledger_entries_append_only BEFORE UPDATE OR DELETE ON wallet_ledger_entries FOR EACH ROW EXECUTE FUNCTION reject_wallet_ledger_mutation();

UPDATE alembic_version SET version_num='0010_usdt_wallet' WHERE alembic_version.version_num = '0009_red_packet_claims';

-- Running upgrade 0010_usdt_wallet -> 0011_wallet_webhook_events

CREATE TABLE wallet_webhook_events (
    event_id VARCHAR(128) NOT NULL, 
    event_type VARCHAR(64) NOT NULL, 
    received_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (event_id)
);

UPDATE alembic_version SET version_num='0011_wallet_webhook_events' WHERE alembic_version.version_num = '0010_usdt_wallet';

-- Running upgrade 0011_wallet_webhook_events -> 0012_friendship

CREATE TABLE friend_requests (
    id VARCHAR(36) NOT NULL, 
    requester_id VARCHAR(36) NOT NULL, 
    target_id VARCHAR(36) NOT NULL, 
    message TEXT NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    resolved_at TIMESTAMP WITH TIME ZONE, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_friend_request_idempotency UNIQUE (requester_id, idempotency_key), 
    FOREIGN KEY(requester_id) REFERENCES users (id), 
    FOREIGN KEY(target_id) REFERENCES users (id)
);

CREATE TABLE friendships (
    id VARCHAR(36) NOT NULL, 
    user_low_id VARCHAR(36) NOT NULL, 
    user_high_id VARCHAR(36) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_friendship_pair UNIQUE (user_low_id, user_high_id), 
    FOREIGN KEY(user_low_id) REFERENCES users (id), 
    FOREIGN KEY(user_high_id) REFERENCES users (id)
);

CREATE TABLE contact_profiles (
    id VARCHAR(36) NOT NULL, 
    owner_id VARCHAR(36) NOT NULL, 
    contact_id VARCHAR(36) NOT NULL, 
    remark VARCHAR(128), 
    tags TEXT NOT NULL, 
    moments_permission VARCHAR(30) NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_contact_profile UNIQUE (owner_id, contact_id), 
    FOREIGN KEY(owner_id) REFERENCES users (id), 
    FOREIGN KEY(contact_id) REFERENCES users (id)
);

CREATE TABLE user_blocks (
    id VARCHAR(36) NOT NULL, 
    blocker_id VARCHAR(36) NOT NULL, 
    blocked_id VARCHAR(36) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_user_block UNIQUE (blocker_id, blocked_id), 
    FOREIGN KEY(blocker_id) REFERENCES users (id), 
    FOREIGN KEY(blocked_id) REFERENCES users (id)
);

UPDATE alembic_version SET version_num='0012_friendship' WHERE alembic_version.version_num = '0011_wallet_webhook_events';

-- Running upgrade 0012_friendship -> 0013_moments

CREATE TABLE moments (
    id VARCHAR(36) NOT NULL, 
    author_id VARCHAR(36) NOT NULL, 
    text TEXT NOT NULL, 
    visibility VARCHAR(30) NOT NULL, 
    image_urls JSON NOT NULL, 
    include_user_ids JSON NOT NULL, 
    exclude_user_ids JSON NOT NULL, 
    location VARCHAR(255), 
    link_url VARCHAR(2048), 
    status VARCHAR(30) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    deleted_at TIMESTAMP WITH TIME ZONE, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_moment_idempotency UNIQUE (author_id, idempotency_key), 
    FOREIGN KEY(author_id) REFERENCES users (id)
);

CREATE TABLE moment_likes (
    id VARCHAR(36) NOT NULL, 
    moment_id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_moment_like UNIQUE (moment_id, user_id), 
    CONSTRAINT uq_moment_like_idempotency UNIQUE (user_id, idempotency_key), 
    FOREIGN KEY(moment_id) REFERENCES moments (id), 
    FOREIGN KEY(user_id) REFERENCES users (id)
);

CREATE TABLE moment_comments (
    id VARCHAR(36) NOT NULL, 
    moment_id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    parent_id VARCHAR(36), 
    text TEXT NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    deleted_at TIMESTAMP WITH TIME ZONE, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_moment_comment_idempotency UNIQUE (user_id, idempotency_key), 
    FOREIGN KEY(moment_id) REFERENCES moments (id), 
    FOREIGN KEY(user_id) REFERENCES users (id)
);

UPDATE alembic_version SET version_num='0013_moments' WHERE alembic_version.version_num = '0012_friendship';

-- Running upgrade 0013_moments -> 0014_moments_prefs

CREATE TABLE moments_preferences (
    user_id VARCHAR(36) NOT NULL, 
    history_range VARCHAR(20) NOT NULL, 
    personalized_recommendations BOOLEAN NOT NULL, 
    cover_url VARCHAR(2048), 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (user_id), 
    FOREIGN KEY(user_id) REFERENCES users (id)
);

CREATE TABLE moment_reports (
    id VARCHAR(36) NOT NULL, 
    moment_id VARCHAR(36) NOT NULL, 
    reporter_id VARCHAR(36) NOT NULL, 
    reason_code VARCHAR(100) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_moment_report_idempotency UNIQUE (reporter_id, idempotency_key), 
    FOREIGN KEY(moment_id) REFERENCES moments (id), 
    FOREIGN KEY(reporter_id) REFERENCES users (id)
);

UPDATE alembic_version SET version_num='0014_moments_prefs' WHERE alembic_version.version_num = '0013_moments';

-- Running upgrade 0014_moments_prefs -> 0015_contact_tags

CREATE TABLE contact_tags (
    id VARCHAR(36) NOT NULL, 
    owner_id VARCHAR(36) NOT NULL, 
    name VARCHAR(64) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_contact_tag_owner_name UNIQUE (owner_id, name), 
    FOREIGN KEY(owner_id) REFERENCES users (id)
);

CREATE INDEX ix_contact_tags_owner_id ON contact_tags (owner_id);

UPDATE alembic_version SET version_num='0015_contact_tags' WHERE alembic_version.version_num = '0014_moments_prefs';

-- Running upgrade 0015_contact_tags -> 0016_moment_media

CREATE TABLE moment_media_uploads (
    id VARCHAR(36) NOT NULL, 
    owner_id VARCHAR(36) NOT NULL, 
    file_name VARCHAR(255) NOT NULL, 
    mime_type VARCHAR(100) NOT NULL, 
    byte_size INTEGER NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    object_key VARCHAR(512) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_moment_media_upload_idempotency UNIQUE (owner_id, idempotency_key), 
    FOREIGN KEY(owner_id) REFERENCES users (id), 
    UNIQUE (object_key)
);

CREATE INDEX ix_moment_media_uploads_owner_id ON moment_media_uploads (owner_id);

CREATE INDEX ix_moment_media_uploads_status ON moment_media_uploads (status);

UPDATE alembic_version SET version_num='0016_moment_media' WHERE alembic_version.version_num = '0015_contact_tags';

-- Running upgrade 0016_moment_media -> 0017_registration_profile

ALTER TABLE users ADD COLUMN nickname VARCHAR(64);

ALTER TABLE users ADD COLUMN signature VARCHAR(140);

ALTER TABLE users ADD COLUMN avatar_object_key VARCHAR(512);

ALTER TABLE users ADD COLUMN profile_updated_at TIMESTAMP WITH TIME ZONE;

UPDATE users SET nickname = username, profile_updated_at = created_at;

ALTER TABLE users ALTER COLUMN nickname SET NOT NULL;

ALTER TABLE users ALTER COLUMN profile_updated_at SET NOT NULL;

ALTER TABLE email_verification_challenges ADD COLUMN registration_session_hash VARCHAR(64);

ALTER TABLE email_verification_challenges ADD COLUMN code_hash VARCHAR(64);

ALTER TABLE email_verification_challenges ADD COLUMN link_token_hash VARCHAR(64);

ALTER TABLE email_verification_challenges ADD COLUMN resend_available_at TIMESTAMP WITH TIME ZONE;

ALTER TABLE email_verification_challenges ADD COLUMN invalidated_at TIMESTAMP WITH TIME ZONE;

CREATE UNIQUE INDEX uq_email_verification_registration_session_hash ON email_verification_challenges (registration_session_hash) WHERE consumed_at IS NULL AND invalidated_at IS NULL;

CREATE INDEX ix_email_verification_active_challenge ON email_verification_challenges (user_id, expires_at) WHERE consumed_at IS NULL AND invalidated_at IS NULL;

UPDATE alembic_version SET version_num='0017_registration_profile' WHERE alembic_version.version_num = '0016_moment_media';

-- Running upgrade 0017_registration_profile -> 0018_avatar_uploads

CREATE TABLE avatar_uploads (
    id VARCHAR(36) NOT NULL, 
    owner_id VARCHAR(36) NOT NULL, 
    mime_type VARCHAR(100) NOT NULL, 
    byte_size INTEGER NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    object_key VARCHAR(512) NOT NULL, 
    content_hash VARCHAR(64), 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    completed_at TIMESTAMP WITH TIME ZONE, 
    cancelled_at TIMESTAMP WITH TIME ZONE, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_avatar_upload_owner_idempotency UNIQUE (owner_id, idempotency_key), 
    FOREIGN KEY(owner_id) REFERENCES users (id), 
    UNIQUE (object_key)
);

CREATE INDEX ix_avatar_uploads_owner_id ON avatar_uploads (owner_id);

CREATE INDEX ix_avatar_uploads_status ON avatar_uploads (status);

UPDATE alembic_version SET version_num='0018_avatar_uploads' WHERE alembic_version.version_num = '0017_registration_profile';

-- Running upgrade 0018_avatar_uploads -> 0019_matrix_profile_sync

ALTER TABLE users ADD COLUMN matrix_avatar_source_key VARCHAR(512);

ALTER TABLE users ADD COLUMN matrix_avatar_mxc_uri VARCHAR(512);

ALTER TABLE users ADD COLUMN matrix_profile_synced_at TIMESTAMP WITH TIME ZONE;

UPDATE alembic_version SET version_num='0019_matrix_profile_sync' WHERE alembic_version.version_num = '0018_avatar_uploads';

-- Running upgrade 0019_matrix_profile_sync -> 0020_friend_request_reuse

ALTER TABLE friend_requests ADD COLUMN requested_at TIMESTAMP WITH TIME ZONE;

UPDATE friend_requests SET requested_at = created_at WHERE requested_at IS NULL;

ALTER TABLE friend_requests ALTER COLUMN requested_at SET NOT NULL;

CREATE INDEX ix_friend_requests_pair_status_requested_at ON friend_requests (requester_id, target_id, status, requested_at);

UPDATE alembic_version SET version_num='0020_friend_request_reuse' WHERE alembic_version.version_num = '0019_matrix_profile_sync';

-- Running upgrade 0020_friend_request_reuse -> 0021_group_auto_join

ALTER TABLE users ADD COLUMN auto_allow_group_join BOOLEAN DEFAULT true NOT NULL;

UPDATE alembic_version SET version_num='0021_group_auto_join' WHERE alembic_version.version_num = '0020_friend_request_reuse';

-- Running upgrade 0021_group_auto_join -> 0022_profile_nudge_suffix

ALTER TABLE users ADD COLUMN nudge_suffix VARCHAR(32);

UPDATE alembic_version SET version_num='0022_profile_nudge_suffix' WHERE alembic_version.version_num = '0021_group_auto_join';

-- Running upgrade 0022_profile_nudge_suffix -> 0023_moments_social_completion

ALTER TABLE moments ADD COLUMN include_tag_ids JSON DEFAULT '[]' NOT NULL;

ALTER TABLE moments ADD COLUMN exclude_tag_ids JSON DEFAULT '[]' NOT NULL;

UPDATE alembic_version SET version_num='0023_moments_social_completion' WHERE alembic_version.version_num = '0022_profile_nudge_suffix';

-- Running upgrade 0023_moments_social_completion -> 0024_moment_notifications

CREATE TABLE moment_notifications (
    id VARCHAR(36) NOT NULL, 
    recipient_id VARCHAR(36) NOT NULL, 
    moment_id VARCHAR(36) NOT NULL, 
    actor_id VARCHAR(36) NOT NULL, 
    kind VARCHAR(20) NOT NULL, 
    comment_id VARCHAR(36), 
    read_at TIMESTAMP WITH TIME ZONE, 
    invalidated_at TIMESTAMP WITH TIME ZONE, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_moment_notification UNIQUE (recipient_id, kind, moment_id, actor_id, comment_id), 
    FOREIGN KEY(recipient_id) REFERENCES users (id), 
    FOREIGN KEY(moment_id) REFERENCES moments (id), 
    FOREIGN KEY(actor_id) REFERENCES users (id)
);

UPDATE alembic_version SET version_num='0024_moment_notifications' WHERE alembic_version.version_num = '0023_moments_social_completion';

-- Running upgrade 0024_moment_notifications -> 0025_moment_drafts_native_ads

CREATE TABLE moment_drafts (
    owner_id VARCHAR(36) NOT NULL, 
    payload JSON NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (owner_id), 
    FOREIGN KEY(owner_id) REFERENCES users (id)
);

CREATE TABLE native_moment_ads (
    id VARCHAR(36) NOT NULL, 
    advertiser_name VARCHAR(128) NOT NULL, 
    avatar_url VARCHAR(2048), 
    text TEXT NOT NULL, 
    image_urls JSON NOT NULL, 
    link_url VARCHAR(2048) NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id)
);

ALTER TABLE moments_preferences ADD COLUMN cover_url VARCHAR(2048);

UPDATE alembic_version SET version_num='0025_moment_drafts_native_ads' WHERE alembic_version.version_num = '0024_moment_notifications';

-- Running upgrade 0025_moment_drafts_native_ads -> 0026_moment_cover_media

ALTER TABLE moment_media_uploads ADD COLUMN purpose VARCHAR(30) DEFAULT 'MOMENT_IMAGE' NOT NULL;

ALTER TABLE moments_preferences ADD COLUMN cover_object_key VARCHAR(512);

UPDATE alembic_version SET version_num='0026_moment_cover_media' WHERE alembic_version.version_num = '0025_moment_drafts_native_ads';

-- Running upgrade 0026_moment_cover_media -> 0027_admin_controls

CREATE TABLE admin_bans (
    id VARCHAR(36) NOT NULL, 
    subject_type VARCHAR(16) NOT NULL, 
    subject_value VARCHAR(255) NOT NULL, 
    reason_code VARCHAR(100) NOT NULL, 
    starts_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    ends_at TIMESTAMP WITH TIME ZONE, 
    revoked_at TIMESTAMP WITH TIME ZONE, 
    created_by VARCHAR(36) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_admin_ban_subject UNIQUE (subject_type, subject_value)
);

CREATE TABLE official_notices (
    id VARCHAR(36) NOT NULL, 
    title VARCHAR(160) NOT NULL, 
    content TEXT NOT NULL, 
    audience VARCHAR(40) NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    publish_at TIMESTAMP WITH TIME ZONE, 
    created_by VARCHAR(36) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_notice_idempotency UNIQUE (created_by, idempotency_key)
);

CREATE TABLE admin_commands (
    id VARCHAR(36) NOT NULL, 
    scope VARCHAR(100) NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    request_hash VARCHAR(64) NOT NULL, 
    result JSON NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_admin_command_idempotency UNIQUE (scope, idempotency_key)
);

UPDATE alembic_version SET version_num='0027_admin_controls' WHERE alembic_version.version_num = '0026_moment_cover_media';

-- Running upgrade 0027_admin_controls -> 0028_notice_receipts_ads

CREATE TABLE notice_receipts (
    id VARCHAR(36) NOT NULL, 
    notice_id VARCHAR(36) NOT NULL, 
    user_id VARCHAR(36) NOT NULL, 
    read_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    idempotency_key VARCHAR(128) NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_notice_receipt_user UNIQUE (notice_id, user_id)
);

CREATE INDEX ix_notice_receipts_notice_id ON notice_receipts (notice_id);

CREATE INDEX ix_notice_receipts_user_id ON notice_receipts (user_id);

CREATE TABLE native_ad_campaigns (
    id VARCHAR(36) NOT NULL, 
    ad_id VARCHAR(36) NOT NULL, 
    starts_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    ends_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    audience JSON NOT NULL, 
    status VARCHAR(20) NOT NULL, 
    impressions INTEGER DEFAULT '0' NOT NULL, 
    clicks INTEGER DEFAULT '0' NOT NULL, 
    created_by VARCHAR(36) NOT NULL, 
    created_at TIMESTAMP WITH TIME ZONE NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT uq_native_ad_campaign_ad UNIQUE (ad_id)
);

CREATE INDEX ix_native_ad_campaigns_ad_id ON native_ad_campaigns (ad_id);

UPDATE alembic_version SET version_num='0028_notice_receipts_ads' WHERE alembic_version.version_num = '0027_admin_controls';

COMMIT;

