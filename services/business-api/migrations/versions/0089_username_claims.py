"""Expand stable handle ownership; retain previous names and Matrix localparts."""
import re

from alembic import op
import sqlalchemy as sa

revision = '0089_username_claims'
down_revision = '0088_profile_grapheme_limits'
branch_labels = None
depends_on = None

# Match Python casefold for every character that can produce an ASCII handle.
# Leave all other Unicode characters intact so the ASCII regex rejects them.
# translate avoids database-locale-dependent handling of ASCII uppercase I.
_MATRIX_LOCALPART_SQL = "translate(split_part(substring(matrix_user_id FROM 2), ':', 1), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')"
for _source, _target in (('ß', 'ss'), ('ſ', 's'), ('ẞ', 'ss'), ('K', 'k'),
                         ('ﬀ', 'ff'), ('ﬁ', 'fi'), ('ﬂ', 'fl'), ('ﬃ', 'ffi'),
                         ('ﬄ', 'ffl'), ('ﬅ', 'st'), ('ﬆ', 'st')):
    _MATRIX_LOCALPART_SQL = f"replace({_MATRIX_LOCALPART_SQL}, '{_source}', '{_target}')"

# Offline scripts run this ownership check before any schema changes.
_OWNERS_SQL = """
SELECT username_normalized AS normalized, id AS owner_user_id, created_at FROM users
UNION
SELECT """ + _MATRIX_LOCALPART_SQL + """, id, created_at
FROM users
WHERE matrix_user_id LIKE '@%:%'
  AND """ + _MATRIX_LOCALPART_SQL + """ ~ '^[a-z][a-z0-9_-]{2,63}$'
"""


def upgrade():
    if op.get_context().as_sql:
        op.execute(sa.text("""
DO $username_claims$
BEGIN
    IF EXISTS (SELECT normalized FROM (""" + _OWNERS_SQL + """) AS owners
               GROUP BY normalized HAVING count(DISTINCT owner_user_id) > 1) THEN
        RAISE EXCEPTION 'ambiguous username ownership; migration stopped';
    END IF;
END
$username_claims$;
"""))
        claims = _expand_schema()
        op.execute(sa.text('INSERT INTO identity_username_claims (normalized, owner_user_id, created_at) '
                           + _OWNERS_SQL))
        return
    connection = op.get_bind()
    users = sa.table('users', sa.column('id', sa.String(36)),
        sa.column('username_normalized', sa.String(64)),
        sa.column('matrix_user_id', sa.String(255)),
        sa.column('created_at', sa.DateTime(timezone=True)))
    owners = {}
    for row in connection.execute(sa.select(users)).mappings():
        names = {row['username_normalized']}
        matrix_id = row['matrix_user_id']
        if matrix_id and matrix_id.startswith('@') and ':' in matrix_id:
            localpart = matrix_id[1:].split(':', 1)[0].casefold()
            # These are every localpart that a compatible registration can
            # claim. Other Matrix formats are not valid business usernames.
            if re.fullmatch(r'[a-z][a-z0-9_-]{2,63}', localpart):
                names.add(localpart)
        for normalized in names:
            existing = owners.get(normalized)
            if existing is not None and existing['owner_user_id'] != row['id']:
                raise RuntimeError('ambiguous username ownership; migration stopped')
            owners[normalized] = {'normalized': normalized,
                'owner_user_id': row['id'], 'created_at': row['created_at']}
    claims = _expand_schema()
    if owners:
        op.bulk_insert(claims, list(owners.values()))


def _expand_schema():
    op.add_column('users', sa.Column('username_changed_at', sa.DateTime(timezone=True), nullable=True))
    claims = op.create_table('identity_username_claims',
        sa.Column('normalized', sa.String(64), primary_key=True),
        sa.Column('owner_user_id', sa.String(36), sa.ForeignKey('users.id'), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False))
    op.create_index('ix_identity_username_claims_owner_user_id', 'identity_username_claims', ['owner_user_id'])
    return claims


def downgrade():
    raise RuntimeError('Username ownership is retained; roll back the application without dropping claims')
