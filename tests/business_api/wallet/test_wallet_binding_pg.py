"""Opt-in migrated, disposable loopback PostgreSQL concurrency validation."""
from concurrent.futures import ThreadPoolExecutor
import os
from threading import Barrier

import pytest
from sqlalchemy import create_engine, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError

from app.core.database import create_session_factory
from app.core.errors import AppError
from app.modules.wallet.binding import WalletBindingService, VerifiedBindingBarrier
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding
from app.integrations.tron.message_signature import address_from_public_key
from tests.business_api.wallet.test_wallet_binding import sign


@pytest.mark.skipif(not os.environ.get("WALLET_BINDING_TEST_DATABASE_URL"), reason="requires isolated migrated PostgreSQL")
def test_pg_concurrent_address_claim_and_immutable_history():
    from coincurve import PrivateKey
    url = make_url(os.environ["WALLET_BINDING_TEST_DATABASE_URL"])
    assert url.host == "127.0.0.1" and url.database == "wallet_binding_verify"
    engine = create_engine(url)
    factory = create_session_factory(engine)
    key = PrivateKey()
    address = address_from_public_key(key.public_key.format(compressed=False))
    service = WalletBindingService(factory, domain="wallet.example.invalid",
        mfa_verifier=lambda **kwargs: True, permission_verifier=lambda **kwargs: True)
    challenges = {user: service.challenge(user_id=user, session_id=user, address=address,
        expected_version=0, idempotency_key="pg-challenge") for user in ("pg-alice", "pg-bob")}
    barrier = Barrier(2)

    def claim(user):
        barrier.wait(timeout=5)
        try:
            challenge = challenges[user]
            return user, service.confirm(user_id=user, session_id=user, challenge_id=challenge["id"],
                signature=sign(key, challenge["message"]), mfa_proof="isolated-test", idempotency_key="pg-confirm")
        except AppError as error:
            return user, error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(claim, challenges))
    successes = [(user, result) for user, result in results if isinstance(result, dict)]
    assert len(successes) == 1
    assert [result for _, result in results if isinstance(result, str)] == ["WALLET_ADDRESS_OWNED"]
    user, result = successes[0]
    service.barrier_verifier = lambda **kwargs: VerifiedBindingBarrier(height=100,
        block_id="a" * 64, network="tron-mainnet", source_ids=("isolated-a", "isolated-b"),
        binding_id=kwargs["binding"].id, observed_at=kwargs["now"])
    service.activate_pending(user_id=user, binding_id=result["id"])
    with pytest.raises(DBAPIError), engine.begin() as connection:
        connection.execute(text("UPDATE wallet_address_owners SET user_id='other'"))
    with pytest.raises(DBAPIError), engine.begin() as connection:
        connection.execute(text("UPDATE wallet_bindings SET barrier_source_ids='[\"forged-a\",\"forged-b\"]'"))
    with factory() as session:
        assert session.scalar(select(WalletAddressOwner)).user_id == user
        assert session.scalar(select(WalletBinding)).barrier_source_ids == ["isolated-a", "isolated-b"]
    engine.dispose()
