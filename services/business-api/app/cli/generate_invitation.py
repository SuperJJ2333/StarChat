"""Issue a one-use invitation code for a 30-day registration window."""

from __future__ import annotations

import argparse
import secrets
from datetime import datetime, timedelta, timezone

from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.modules.identity.invitations import InvitationService


DEFAULT_MAX_USES = 1
DEFAULT_VALID_DAYS = 30


def generate_invitation(*, created_by: str, now: datetime | None = None) -> tuple[str, datetime]:
    """Create a high-entropy code and its expiry without persisting plaintext."""
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    return secrets.token_urlsafe(24), current + timedelta(days=DEFAULT_VALID_DAYS)


def issue_invitation(*, settings: Settings, created_by: str) -> tuple[str, datetime]:
    code, expires_at = generate_invitation(created_by=created_by)
    service = InvitationService(create_session_factory(create_engine(settings)))
    service.issue(
        code=code,
        max_uses=DEFAULT_MAX_USES,
        expires_at=expires_at,
        created_by=created_by,
    )
    return code, expires_at


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--created-by",
        default="server-admin",
        help="Audit identity recorded on the invitation (default: server-admin)",
    )
    args = parser.parse_args()
    code, expires_at = issue_invitation(settings=Settings(), created_by=args.created_by)
    print(f"activation_code={code}")
    print(f"expires_at={expires_at.isoformat()}")
    print(f"max_uses={DEFAULT_MAX_USES}")


if __name__ == "__main__":
    main()
