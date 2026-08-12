import pytest
from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.idempotency import IdempotencyService


@pytest.fixture()
def service() -> IdempotencyService:
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    from app.core import idempotency as _idempotency  # noqa: F401

    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    yield IdempotencyService(factory)
    engine.dispose()


def test_completed_request_is_replayed(service: IdempotencyService) -> None:
    first = service.begin("wallet.withdraw", "request-1", "hash-a")
    assert first.replay is False

    service.complete(
        "wallet.withdraw",
        "request-1",
        "hash-a",
        response_status=202,
        response_body={"withdrawal_id": "w-1"},
    )

    replay = service.begin("wallet.withdraw", "request-1", "hash-a")
    assert replay.replay is True
    assert replay.response_status == 202
    assert replay.response_body == {"withdrawal_id": "w-1"}


def test_reusing_key_with_different_request_hash_is_rejected(
    service: IdempotencyService,
) -> None:
    service.begin("ledger.transfer", "request-1", "hash-a")

    with pytest.raises(AppError, match="request hash") as exc_info:
        service.begin("ledger.transfer", "request-1", "hash-b")

    assert exc_info.value.code == "IDEMPOTENCY_KEY_REUSED"
    assert exc_info.value.status_code == 409


def test_in_progress_request_cannot_be_started_twice(service: IdempotencyService) -> None:
    service.begin("ledger.transfer", "request-1", "hash-a")

    with pytest.raises(AppError) as exc_info:
        service.begin("ledger.transfer", "request-1", "hash-a")

    assert exc_info.value.code == "IDEMPOTENCY_IN_PROGRESS"


def test_unknown_request_cannot_be_completed(service: IdempotencyService) -> None:
    with pytest.raises(AppError) as exc_info:
        service.complete(
            "ledger.transfer",
            "missing",
            "hash-a",
            response_status=200,
            response_body={},
        )

    assert exc_info.value.code == "IDEMPOTENCY_NOT_FOUND"
