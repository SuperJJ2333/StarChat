"""Media Platform tables (Media Engine Phase 4.1).

Expand-only: creates seven new tables plus their indexes. No existing table, column,
constraint or index is touched, so the migration is safe to run online and can be left in
place while the platform is gradually adopted (strangler pattern).

Partial unique indexes encode two frozen rules:
* only a *reusable* object reserves its digest slot, so random-envelope uploads of the
  same bytes can coexist and two owners never share a plaintext slot;
* only an *active* reference/grant is unique, so released rows stay for audit and a
  business object may re-attach the same media later.
"""
from alembic import op
import sqlalchemy as sa

revision = '0069_media_platform'
down_revision = '0068_red_packet_fee'
branch_labels = None
depends_on = None

DIGEST_SLOT = "dedup_eligible AND status <> 'DELETED'"
ACTIVE_REFERENCE = "state = 'active'"
ACTIVE_GRANT = "revoked_at IS NULL"


def upgrade():
    op.create_table(
        'media_objects',
        sa.Column('media_id', sa.String(36), primary_key=True),
        sa.Column('owner_id', sa.String(36), nullable=False),
        sa.Column('owner_scope', sa.String(80), nullable=False),
        sa.Column('isolation_domain', sa.String(20), nullable=False),
        sa.Column('origin_domain', sa.String(20), nullable=False),
        sa.Column('kind', sa.String(16), nullable=False),
        sa.Column('canonical_mime', sa.String(120), nullable=False),
        sa.Column('canonical_size', sa.BigInteger(), nullable=False),
        sa.Column('width', sa.Integer(), nullable=True),
        sa.Column('height', sa.Integer(), nullable=True),
        sa.Column('duration_ms', sa.BigInteger(), nullable=True),
        sa.Column('digest_kind', sa.String(32), nullable=False),
        sa.Column('digest_version', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('content_digest', sa.String(64), nullable=False),
        sa.Column('envelope_mode', sa.String(24), nullable=False),
        sa.Column('envelope_version', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('dedup_eligible', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('status', sa.String(16), nullable=False, server_default='ACTIVE'),
        sa.Column('visibility_hint', sa.String(16), nullable=False, server_default='private'),
        sa.Column('ref_count', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('metadata', sa.JSON(), nullable=True),
        sa.Column('pinned_until', sa.DateTime(timezone=True), nullable=True),
        sa.Column('quarantined_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('quarantine_reason', sa.String(60), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('ready_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('unreferenced_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('last_access_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('deleting_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('deleted_at', sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index('ix_media_objects_owner_id', 'media_objects', ['owner_id'])
    op.create_index('ix_media_objects_origin_domain', 'media_objects', ['origin_domain'])
    op.create_index('ix_media_objects_owner', 'media_objects', ['owner_id', 'created_at'])
    op.create_index('ix_media_objects_scope', 'media_objects', ['owner_scope', 'status'])
    op.create_index('ix_media_objects_status', 'media_objects', ['status', 'unreferenced_at'])
    op.create_index('ix_media_objects_access', 'media_objects', ['last_access_at'])
    op.create_index(
        'uq_media_objects_digest_slot',
        'media_objects',
        ['owner_scope', 'digest_kind', 'digest_version', 'envelope_version', 'content_digest'],
        unique=True,
        sqlite_where=sa.text(DIGEST_SLOT),
        postgresql_where=sa.text(DIGEST_SLOT),
    )

    op.create_table(
        'media_blobs',
        sa.Column('blob_id', sa.String(36), primary_key=True),
        sa.Column('object_id', sa.String(36), sa.ForeignKey('media_objects.media_id'), nullable=True),
        sa.Column('owner_id', sa.String(36), nullable=False),
        sa.Column('owner_scope', sa.String(80), nullable=False),
        sa.Column('isolation_domain', sa.String(20), nullable=False),
        sa.Column('digest_kind', sa.String(32), nullable=False),
        sa.Column('digest_version', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('content_digest', sa.String(64), nullable=False),
        sa.Column('size', sa.BigInteger(), nullable=False),
        sa.Column('mime', sa.String(120), nullable=False),
        sa.Column('storage_backend', sa.String(24), nullable=False, server_default='local_private'),
        sa.Column('storage_key', sa.String(512), nullable=False, unique=True),
        sa.Column('envelope_mode', sa.String(24), nullable=False, server_default='none'),
        sa.Column('envelope_version', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('dedup_eligible', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('status', sa.String(16), nullable=False, server_default='STAGED'),
        sa.Column('pinned_until', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('verified_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('retiring_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('deleted_at', sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index('ix_media_blobs_owner_id', 'media_blobs', ['owner_id'])
    op.create_index('ix_media_blobs_object', 'media_blobs', ['object_id'])
    op.create_index('ix_media_blobs_status', 'media_blobs', ['status', 'retiring_at'])
    op.create_index('ix_media_blobs_scope', 'media_blobs', ['owner_scope', 'status'])
    op.create_index(
        'uq_media_blobs_digest_slot',
        'media_blobs',
        ['isolation_domain', 'digest_kind', 'digest_version', 'envelope_version', 'content_digest'],
        unique=True,
        sqlite_where=sa.text(DIGEST_SLOT),
        postgresql_where=sa.text(DIGEST_SLOT),
    )

    op.create_table(
        'media_variants',
        sa.Column('variant_id', sa.String(36), primary_key=True),
        sa.Column('media_id', sa.String(36), sa.ForeignKey('media_objects.media_id'), nullable=False),
        sa.Column('kind', sa.String(24), nullable=False),
        sa.Column('blob_id', sa.String(36), sa.ForeignKey('media_blobs.blob_id'), nullable=True),
        sa.Column('status', sa.String(16), nullable=False, server_default='pending'),
        sa.Column('mime', sa.String(120), nullable=True),
        sa.Column('codec', sa.String(40), nullable=True),
        sa.Column('width', sa.Integer(), nullable=True),
        sa.Column('height', sa.Integer(), nullable=True),
        sa.Column('duration_ms', sa.BigInteger(), nullable=True),
        sa.Column('bitrate_bps', sa.Integer(), nullable=True),
        sa.Column('size', sa.BigInteger(), nullable=True),
        sa.Column('generation', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('derived_from', sa.String(24), nullable=True),
        sa.Column('is_primary', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('failure_reason', sa.String(40), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('ready_at', sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index('ix_media_variants_media_id', 'media_variants', ['media_id'])
    op.create_index('ix_media_variants_blob', 'media_variants', ['blob_id'])
    op.create_index('ix_media_variants_ready', 'media_variants', ['media_id', 'kind', 'status'])
    op.create_index('ix_media_variants_queue', 'media_variants', ['status', 'created_at'])
    op.create_index(
        'uq_media_variants_kind',
        'media_variants',
        ['media_id', 'kind', 'generation'],
        unique=True,
    )

    op.create_table(
        'media_references',
        sa.Column('reference_id', sa.String(36), primary_key=True),
        sa.Column('media_id', sa.String(36), sa.ForeignKey('media_objects.media_id'), nullable=False),
        sa.Column('owner_id', sa.String(36), nullable=False),
        sa.Column('variant_kind', sa.String(24), nullable=True),
        sa.Column('business_type', sa.String(32), nullable=False),
        sa.Column('business_id', sa.String(160), nullable=False),
        sa.Column('room_ref', sa.String(160), nullable=True),
        sa.Column('permission_scope', sa.String(16), nullable=False, server_default='private'),
        sa.Column('ref_kind', sa.String(16), nullable=False, server_default='observed'),
        sa.Column('state', sa.String(16), nullable=False, server_default='active'),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('released_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('release_reason', sa.String(32), nullable=True),
    )
    op.create_index('ix_media_references_owner_id', 'media_references', ['owner_id'])
    op.create_index('ix_media_references_lookup', 'media_references', ['business_type', 'business_id'])
    op.create_index('ix_media_references_media', 'media_references', ['media_id', 'state'])
    op.create_index('ix_media_references_scope', 'media_references', ['owner_id', 'created_at'])
    op.create_index(
        'uq_media_references_active',
        'media_references',
        ['media_id', 'business_type', 'business_id'],
        unique=True,
        sqlite_where=sa.text(ACTIVE_REFERENCE),
        postgresql_where=sa.text(ACTIVE_REFERENCE),
    )

    op.create_table(
        'media_access_grants',
        sa.Column('grant_id', sa.String(36), primary_key=True),
        sa.Column('media_id', sa.String(36), sa.ForeignKey('media_objects.media_id'), nullable=False),
        sa.Column('variant_scope', sa.JSON(), nullable=False),
        sa.Column('subject_type', sa.String(16), nullable=False),
        sa.Column('subject_id', sa.String(160), nullable=False),
        sa.Column('permission', sa.String(24), nullable=False),
        sa.Column('derived_from', sa.JSON(), nullable=True),
        sa.Column('grant_version', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('single_use', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('uses', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('max_uses', sa.Integer(), nullable=True),
        sa.Column('issued_by', sa.String(36), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('revoked_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('revoke_reason', sa.String(60), nullable=True),
    )
    op.create_index('ix_media_access_grants_expiry', 'media_access_grants', ['expires_at'])
    op.create_index(
        'ix_media_access_grants_subject',
        'media_access_grants',
        ['subject_type', 'subject_id', 'media_id'],
    )
    op.create_index(
        'uq_media_access_grants_subject',
        'media_access_grants',
        ['media_id', 'subject_type', 'subject_id', 'permission'],
        unique=True,
        sqlite_where=sa.text(ACTIVE_GRANT),
        postgresql_where=sa.text(ACTIVE_GRANT),
    )

    op.create_table(
        'media_upload_sessions',
        sa.Column('upload_id', sa.String(36), primary_key=True),
        sa.Column('owner_id', sa.String(36), nullable=False),
        sa.Column('origin_domain', sa.String(20), nullable=False),
        sa.Column('kind', sa.String(16), nullable=False),
        sa.Column('declared_size', sa.BigInteger(), nullable=False),
        sa.Column('declared_mime', sa.String(120), nullable=False),
        sa.Column('digest_claim', sa.String(64), nullable=True),
        sa.Column('digest_claim_kind', sa.String(32), nullable=True),
        sa.Column('envelope_mode', sa.String(24), nullable=False),
        sa.Column('envelope_version', sa.Integer(), nullable=False, server_default='1'),
        sa.Column('part_size', sa.BigInteger(), nullable=False),
        sa.Column('chunks', sa.JSON(), nullable=False),
        sa.Column('uploaded_bytes', sa.BigInteger(), nullable=False, server_default='0'),
        sa.Column('status', sa.String(16), nullable=False, server_default='created'),
        sa.Column('media_id', sa.String(36), nullable=True),
        sa.Column('idempotency_key', sa.String(128), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index('ix_media_upload_owner_id', 'media_upload_sessions', ['owner_id'])
    op.create_index('ix_media_upload_status', 'media_upload_sessions', ['status', 'expires_at'])
    op.create_index('ix_media_upload_owner', 'media_upload_sessions', ['owner_id', 'created_at'])
    op.create_index(
        'uq_media_upload_idempotency',
        'media_upload_sessions',
        ['owner_id', 'idempotency_key'],
        unique=True,
    )

    op.create_table(
        'media_gc_runs',
        sa.Column('run_id', sa.String(36), primary_key=True),
        sa.Column('mode', sa.String(12), nullable=False),
        sa.Column('scope', sa.String(80), nullable=False),
        sa.Column('scanned', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('candidates', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('collected', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('skipped_pinned', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('skipped_referenced', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('skipped_grace', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('skipped_quarantined', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('bytes_reclaimed', sa.BigInteger(), nullable=False, server_default='0'),
        sa.Column('decisions', sa.JSON(), nullable=False),
        sa.Column('started_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('finished_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('error_code', sa.String(60), nullable=True),
    )
    op.create_index('ix_media_gc_runs_started', 'media_gc_runs', ['started_at'])


def downgrade():
    op.drop_index('ix_media_gc_runs_started', table_name='media_gc_runs')
    op.drop_table('media_gc_runs')
    op.drop_index('uq_media_upload_idempotency', table_name='media_upload_sessions')
    op.drop_index('ix_media_upload_owner', table_name='media_upload_sessions')
    op.drop_index('ix_media_upload_status', table_name='media_upload_sessions')
    op.drop_index('ix_media_upload_owner_id', table_name='media_upload_sessions')
    op.drop_table('media_upload_sessions')
    op.drop_index('uq_media_access_grants_subject', table_name='media_access_grants')
    op.drop_index('ix_media_access_grants_subject', table_name='media_access_grants')
    op.drop_index('ix_media_access_grants_expiry', table_name='media_access_grants')
    op.drop_table('media_access_grants')
    op.drop_index('uq_media_references_active', table_name='media_references')
    op.drop_index('ix_media_references_scope', table_name='media_references')
    op.drop_index('ix_media_references_media', table_name='media_references')
    op.drop_index('ix_media_references_lookup', table_name='media_references')
    op.drop_index('ix_media_references_owner_id', table_name='media_references')
    op.drop_table('media_references')
    op.drop_index('uq_media_variants_kind', table_name='media_variants')
    op.drop_index('ix_media_variants_queue', table_name='media_variants')
    op.drop_index('ix_media_variants_ready', table_name='media_variants')
    op.drop_index('ix_media_variants_blob', table_name='media_variants')
    op.drop_index('ix_media_variants_media_id', table_name='media_variants')
    op.drop_table('media_variants')
    op.drop_index('uq_media_blobs_digest_slot', table_name='media_blobs')
    op.drop_index('ix_media_blobs_scope', table_name='media_blobs')
    op.drop_index('ix_media_blobs_status', table_name='media_blobs')
    op.drop_index('ix_media_blobs_object', table_name='media_blobs')
    op.drop_index('ix_media_blobs_owner_id', table_name='media_blobs')
    op.drop_table('media_blobs')
    op.drop_index('uq_media_objects_digest_slot', table_name='media_objects')
    op.drop_index('ix_media_objects_access', table_name='media_objects')
    op.drop_index('ix_media_objects_status', table_name='media_objects')
    op.drop_index('ix_media_objects_scope', table_name='media_objects')
    op.drop_index('ix_media_objects_owner', table_name='media_objects')
    op.drop_index('ix_media_objects_origin_domain', table_name='media_objects')
    op.drop_index('ix_media_objects_owner_id', table_name='media_objects')
    op.drop_table('media_objects')
