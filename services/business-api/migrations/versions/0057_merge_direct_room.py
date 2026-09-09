"""Join reviewed pair reservations to the deployed migration graph."""
revision = "0057_merge_direct_room"
down_revision = ("0056_merge_moment_comments", "0040_direct_room_reservations")
branch_labels = None
depends_on = None
def upgrade():
    pass
def downgrade():
    raise RuntimeError("Never downgrade pair reservations; retain schema and reconcile explicitly")
