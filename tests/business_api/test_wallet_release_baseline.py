"""A wallet release must retain both independently deployed migration branches."""
from pathlib import Path
import importlib.util

from alembic.config import Config
from alembic.script import ScriptDirectory


def test_wallet_and_moments_production_branches_have_one_shared_head():
    root = Path(__file__).resolve().parents[2] / 'services/business-api'
    config = Config(str(root / 'alembic.ini'))
    config.set_main_option('script_location', str(root / 'migrations'))
    scripts = ScriptDirectory.from_config(config)
    assert len(scripts.get_heads()) == 1
    ancestors = {revision.revision for revision in scripts.walk_revisions()}
    assert {'0055_admin_sessions', '0040_moment_comment_images',
            '0056_merge_moment_comments'} <= ancestors
    merge = scripts.get_revision('0056_merge_moment_comments')
    assert set(merge.down_revision) == {
        '0055_admin_sessions', '0040_moment_comment_images'}
    assert scripts.get_heads() == ['0058_moments_privacy']
    assert set(scripts.get_revision('0057_merge_direct_room').down_revision) == {
        '0056_merge_moment_comments', '0040_direct_room_reservations'}


def test_release_preflight_pins_the_integrated_migration_head():
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location(
        'integrated_wallet_preflight', root / 'scripts/wallet_release_preflight.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    assert helper.EXPECTED_HEAD == '0058_moments_privacy'
