"""A wallet release must retain both independently deployed migration branches."""
from pathlib import Path
import importlib.util

from alembic.config import Config
from alembic.script import ScriptDirectory


def test_wallet_and_moments_production_branches_have_one_shared_head():
    root = Path(__file__).resolve().parents[2] / 'services/business-api'
    config = Config(str(root / 'alembic.ini'))
    config.set_main_option('script_location', str(root / 'migrations'))
    config.set_main_option('path_separator', 'os')
    scripts = ScriptDirectory.from_config(config)
    assert len(scripts.get_heads()) == 1
    ancestors = {revision.revision for revision in scripts.walk_revisions()}
    assert {'0055_admin_sessions', '0040_moment_comment_images',
            '0056_merge_moment_comments'} <= ancestors
    merge = scripts.get_revision('0056_merge_moment_comments')
    assert set(merge.down_revision) == {
        '0055_admin_sessions', '0040_moment_comment_images'}
    # 2026-09-21：迁移链扩至 0080（ADR-0075..0079 及实施补充），仍单头。
    assert scripts.get_heads() == ['0083_phone_wallet_refresh_merge']
    assert set(scripts.get_revision('0083_phone_wallet_refresh_merge').down_revision) == {
        '0080_refresh_recovery', '0082_deposit_intent_cancel'}
    assert scripts.get_revision('0080_refresh_recovery').down_revision == '0071_direct_room_generations'
    assert scripts.get_revision('0078_phone_accounts').down_revision == '0077_recharge_requests'
    assert scripts.get_revision('0072_fx_rates').down_revision == '0071_direct_room_generations'
    assert scripts.get_revision('0070_direct_room_history').down_revision == '0069_media_platform'
    assert scripts.get_revision('0069_media_platform').down_revision == '0068_red_packet_fee'
    assert scripts.get_revision('0068_red_packet_fee').down_revision == '0067_wallet_owner_transfers'
    assert scripts.get_revision('0067_wallet_owner_transfers').down_revision == '0066_manual_deposit_cases'
    assert scripts.get_revision('0066_manual_deposit_cases').down_revision == '0065_support_profiles'
    assert scripts.get_revision('0065_support_profiles').down_revision == '0064_admin_deposit_repairs'
    assert scripts.get_revision('0064_admin_deposit_repairs').down_revision == '0063_merge_wallet_access'
    assert set(scripts.get_revision('0063_merge_wallet_access').down_revision) == {
        '0062_matrix_login_broker', '0062_wallet_access_grant'}
    assert '0060_merge_release_parity' in ancestors
    assert scripts.get_revision('0062_matrix_login_broker').down_revision == '0061_mobile_matrix_session'
    assert scripts.get_revision('0061_mobile_matrix_session').down_revision == '0060_merge_release_parity'
    assert set(scripts.get_revision('0057_merge_direct_room').down_revision) == {
        '0056_merge_moment_comments', '0040_direct_room_reservations'}


def test_release_preflight_pins_the_integrated_migration_head():
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location(
        'integrated_wallet_preflight', root / 'scripts/wallet_release_preflight.py')
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    assert helper.EXPECTED_HEAD == '0066_manual_deposit_cases'
    assert 'wallet_manual_deposit_cases' in helper.REQUIRED_COLUMNS
