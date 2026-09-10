"""Merge independent mobile and wallet schema release branches."""
revision = '0063_merge_wallet_access'
down_revision = ('0062_matrix_login_broker', '0062_wallet_access_grant')
branch_labels = None
depends_on = None


def upgrade():
    pass


def downgrade():
    raise RuntimeError('Retain expanded schemas; use application rollback')
