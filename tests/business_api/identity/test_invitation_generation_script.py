from datetime import datetime, timezone

from app.cli.generate_invitation import DEFAULT_MAX_USES, DEFAULT_VALID_DAYS, generate_invitation


def test_generate_invitation_uses_one_use_and_thirty_day_expiry() -> None:
    now = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)
    code, expires_at = generate_invitation(created_by="server-admin", now=now)

    assert len(code) >= 32
    assert expires_at == now.replace(day=18, month=9)
    assert DEFAULT_MAX_USES == 1
    assert DEFAULT_VALID_DAYS == 30
