from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


PROJECT_ROOT = Path(__file__).resolve().parents[2]
BUSINESS_API_ROOT = PROJECT_ROOT / "services" / "business-api"


def _alembic(*arguments: str) -> str:
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(BUSINESS_API_ROOT)
    completed = subprocess.run(
        [sys.executable, "-m", "alembic", *arguments],
        cwd=BUSINESS_API_ROOT,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return completed.stdout


def _normalized_sql(sql: str) -> str:
    return " ".join(sql.lower().split())


def test_group_auto_join_migration_extends_friend_request_reuse() -> None:
    revision = (BUSINESS_API_ROOT / "migrations" / "versions" / "0021_group_auto_join.py").read_text(
        encoding="utf-8"
    )
    assert "down_revision = '0020_friend_request_reuse'" in revision


def test_admin_controls_migration_is_the_only_head() -> None:
    assert _alembic("heads").strip() == "0035_direct_conversations (head)"


def test_chat_transfer_migration_chains_after_notice_receipts() -> None:
    revision = (BUSINESS_API_ROOT / "migrations" / "versions" / "0029_chat_transfers.py").read_text(encoding="utf-8")
    assert 'down_revision = "0028_notice_receipts_ads"' in revision
    sql = _normalized_sql(_alembic("upgrade", "head", "--sql"))
    assert "create table chat_transfers" in sql
    assert "create table app_settings" in sql

def test_registration_profile_upgrade_expands_backfills_then_enforces_profile_fields() -> None:
    sql = _normalized_sql(_alembic("upgrade", "head", "--sql"))

    add_nickname = sql.index("alter table users add column nickname varchar(64)")
    add_profile_updated_at = sql.index(
        "alter table users add column profile_updated_at timestamp with time zone"
    )
    backfill = sql.index(
        "update users set nickname = username, profile_updated_at = created_at"
    )
    require_nickname = sql.index("alter table users alter column nickname set not null")
    require_profile_updated_at = sql.index(
        "alter table users alter column profile_updated_at set not null"
    )

    assert add_nickname < backfill < require_nickname
    assert add_profile_updated_at < backfill < require_profile_updated_at
    assert "alter table users add column signature varchar(140)" in sql
    assert "alter table users add column avatar_object_key varchar(512)" in sql
    assert (
        "alter table email_verification_challenges add column "
        "registration_session_hash varchar(64)"
    ) in sql
    assert "add column code_hash varchar(64)" in sql
    assert "add column link_token_hash varchar(64)" in sql
    assert "add column resend_available_at timestamp with time zone" in sql
    assert "add column invalidated_at timestamp with time zone" in sql
    assert "create unique index uq_email_verification_registration_session_hash" in sql
    assert "create index ix_email_verification_active_challenge" in sql


def test_registration_profile_downgrade_removes_only_new_objects() -> None:
    sql = _normalized_sql(
        _alembic(
            "downgrade",
            "0017_registration_profile:0016_moment_media",
            "--sql",
        )
    )

    assert "drop table users" not in sql
    assert "drop table email_verification_challenges" not in sql
    assert "drop column token_hash" not in sql
    assert "drop column nickname" in sql
    assert "drop column registration_session_hash" in sql


def test_avatar_upload_migration_adds_private_upload_state_and_safe_downgrade() -> None:
    upgrade_sql = _normalized_sql(
        _alembic(
            "upgrade",
            "0017_registration_profile:0018_avatar_uploads",
            "--sql",
        )
    )
    downgrade_sql = _normalized_sql(
        _alembic(
            "downgrade",
            "0018_avatar_uploads:0017_registration_profile",
            "--sql",
        )
    )

    assert "create table avatar_uploads" in upgrade_sql
    assert "foreign key(owner_id) references users (id)" in upgrade_sql
    assert "uq_avatar_upload_owner_idempotency" in upgrade_sql
    assert "drop table avatar_uploads" in downgrade_sql
    assert "drop table users" not in downgrade_sql


def test_matrix_profile_sync_migration_only_adds_retry_state_to_users() -> None:
    upgrade_sql = _normalized_sql(
        _alembic(
            "upgrade",
            "0018_avatar_uploads:0019_matrix_profile_sync",
            "--sql",
        )
    )
    downgrade_sql = _normalized_sql(
        _alembic(
            "downgrade",
            "0019_matrix_profile_sync:0018_avatar_uploads",
            "--sql",
        )
    )

    assert "add column matrix_avatar_source_key varchar(512)" in upgrade_sql
    assert "add column matrix_avatar_mxc_uri varchar(512)" in upgrade_sql
    assert "add column matrix_profile_synced_at timestamp with time zone" in upgrade_sql
    assert "drop table users" not in downgrade_sql
    assert "drop column matrix_profile_synced_at" in downgrade_sql
