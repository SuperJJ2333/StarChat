from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import TotpCredential, UserRole
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.totp import FernetSecretProtector, TotpService


@pytest.fixture()
def access_components():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add_all(
            [
                UserRole(
                    id="role-1",
                    user_id="support-1",
                    role_code=RoleCode.SUPPORT_AGENT,
                    assigned_by="admin-1",
                    assigned_at=now,
                ),
                UserRole(
                    id="role-2",
                    user_id="admin-1",
                    role_code=RoleCode.SUPER_ADMIN,
                    assigned_by="bootstrap",
                    assigned_at=now,
                ),
            ]
        )
    yield factory, now
    engine.dispose()


def test_rbac_denies_unknown_or_unassigned_permission(access_components) -> None:
    factory, _ = access_components
    rbac = RbacService(factory)

    rbac.require("support-1", Permission.SUPPORT_TICKET_ASSIGN)
    with pytest.raises(AppError) as exc_info:
        rbac.require("support-1", Permission.FINANCE_REVIEW)
    assert exc_info.value.code == "PERMISSION_DENIED"

    with pytest.raises(AppError):
        rbac.require("admin-1", "permission.not_declared")


def test_super_admin_has_declared_permissions_but_no_unknown_bypass(access_components) -> None:
    factory, _ = access_components
    rbac = RbacService(factory)

    for permission in Permission:
        rbac.require("admin-1", permission)
    with pytest.raises(AppError):
        rbac.require("admin-1", "arbitrary.permission")


def test_totp_secret_is_encrypted_and_code_cannot_be_replayed(access_components) -> None:
    factory, now = access_components
    protector = FernetSecretProtector.generate()
    service = TotpService(factory, protector=protector, now_factory=lambda: now)
    enrollment = service.enroll("admin-1")

    with factory() as session:
        credential = session.get(TotpCredential, enrollment.credential_id)
        assert credential.encrypted_secret != enrollment.secret
        assert enrollment.secret not in credential.encrypted_secret

    code = service.code_at(enrollment.secret, now)
    service.enable("admin-1", code)
    service.verify("admin-1", code)

    with pytest.raises(AppError) as exc_info:
        service.verify("admin-1", code)
    assert exc_info.value.code == "TOTP_REPLAYED"


def test_privileged_mutation_requires_recent_totp(access_components) -> None:
    factory, now = access_components
    service = TotpService(
        factory, protector=FernetSecretProtector.generate(), now_factory=lambda: now
    )

    with pytest.raises(AppError) as exc_info:
        service.require_recent("admin-1", verified_at=None, max_age_seconds=300)
    assert exc_info.value.code == "TOTP_REQUIRED"
