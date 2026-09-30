"""Protect production capabilities while integrating the admin entry release."""

from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest
from alembic.config import Config
from alembic.script import ScriptDirectory

from app.core.config import Settings


def test_existing_s3_configuration_rejects_a_remote_custom_endpoint():
    with pytest.raises(ValueError, match="custom S3 endpoint"):
        Settings(
            _env_file=None,
            environment="test",
            media_blob_backend="s3",
            media_s3_region="ap-southeast-1",
            media_s3_bucket="private-media",
            media_s3_endpoint="https://storage.example.test",
        )


def test_existing_local_media_backend_remains_available():
    from app.integrations.media_blob_storage import build_blob_backend
    from app.modules.media.storage import LocalBlobBackend

    backend = build_blob_backend(Settings(_env_file=None))
    assert isinstance(backend, LocalBlobBackend)


def test_existing_account_contact_proof_requires_verification():
    from app.modules.identity.account_credentials import contact_snapshot

    contact = SimpleNamespace(
        email_normalized="person@example.test",
        email_verified_at=None,
    )
    assert contact_snapshot(contact, "email") is None
    contact.email_verified_at = datetime(2026, 9, 28, tzinfo=timezone.utc)
    assert len(contact_snapshot(contact, "email")) == 64


def test_existing_schema_migration_chain_has_one_current_head():
    project = Path(__file__).resolve().parents[2] / "services" / "business-api"
    config = Config(str(project / "alembic.ini"))
    config.set_main_option("path_separator", "os")
    config.set_main_option("script_location", str(project / "migrations"))
    scripts = ScriptDirectory.from_config(config)
    assert scripts.get_heads() == ["0094_support_finance_order_recovery"]
    assert scripts.get_revision("0092_admin_session_entry_mode").down_revision == "0091_moment_video_posters"
    assert scripts.get_revision("0094_support_finance_order_recovery").down_revision == "0093_unbroadcast_payout_void"
