"""Native PostgreSQL constraints for independent manual deposit attribution."""
from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError


API_ROOT = Path(__file__).resolve().parents[3] / "services" / "business-api"
SOURCE_ADDRESS = "TManualDepositSourceAddress0000000"
USDT_TRC20_CONTRACT = "TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj"
OFFICIAL_ADDRESS = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"


def _config(url: str) -> Config:
    config = Config(str(API_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(API_ROOT / "migrations"))
    config.set_main_option("path_separator", "os")
    config.set_main_option("sqlalchemy.url", url.replace("%", "%%"))
    return config


@pytest.fixture
def migrated_schema(monkeypatch):
    """Build the real 0065 schema, then apply only the 0066 expansion."""
    url = os.environ.get("REPORTING_PG_URL")
    if not url:
        pytest.skip("REPORTING_PG_URL required for isolated PostgreSQL migration")
    schema = "manual_deposit_constraints_" + uuid4().hex
    admin = create_engine(url)
    engine = None
    try:
        with admin.begin() as connection:
            connection.execute(text(f"CREATE SCHEMA {schema}"))
        scoped = make_url(url).update_query_dict({"options": f"-csearch_path={schema}"})
        scoped_url = scoped.render_as_string(hide_password=False)
        monkeypatch.setenv("BUSINESS_DATABASE_URL", scoped_url)
        engine = create_engine(scoped)
        config = _config(scoped_url)
        command.upgrade(config, "0065_support_profiles")
        with engine.connect() as connection:
            assert connection.scalar(text("SELECT version_num FROM alembic_version")) == "0065_support_profiles"
            assert connection.scalar(text("SELECT to_regclass('wallet_manual_deposit_cases')")) is None
        command.upgrade(config, "0066_manual_deposit_cases")
        yield engine
    finally:
        if engine is not None:
            engine.dispose()
        with admin.begin() as connection:
            connection.execute(text(f"DROP SCHEMA IF EXISTS {schema} CASCADE"))
        admin.dispose()


def _seed(connection):
    now = datetime.now(timezone.utc)
    connection.execute(text("""
        INSERT INTO wallet_address_owners (address, user_id, created_at)
        VALUES (:source_address, 'right-user', :now)
    """), {"now": now, "source_address": SOURCE_ADDRESS})
    connection.execute(text("""
        INSERT INTO wallet_bindings (
            id, user_id, address, version, status, created_at, activated_at,
            effective_from_block, effective_to_block, barrier_height, barrier_block_id,
            barrier_source_ids, barrier_observed_at, barrier_policy
        ) VALUES (
            'binding-1', 'right-user', :source_address, 1, 'ACTIVE', :now, :now,
            101, NULL, 100, 'barrier-block', '["source"]'::json, :now, 'LEGACY_UNSPECIFIED'
        )
    """), {"now": now, "source_address": SOURCE_ADDRESS})
    connection.execute(text("""
        INSERT INTO wallet_ledger_transactions
            (id, asset, scope, idempotency_key, actor_id, reason_code, created_at)
        VALUES ('ledger-1', 'USDT', 'wallet.deposit.receipt', 'receipt:receipt-1', 'owner', 'MANUAL_DEPOSIT', :now)
    """), {"now": now})
    connection.execute(text("""
        INSERT INTO wallet_deposit_receipts (
            id, network, contract, txid, log_index, source_address, official_address,
            official_config_version, amount_units, amount, block_number, block_id, block_time,
            evidence_policy, evidence_source, observed_at, facts_digest, status, reason_code,
            pending_obligation, intent_id, user_id, ledger_transaction_id
        ) VALUES (
            'receipt-1', 'TRON', :contract, 'a_txid', 0, :source_address, :official_address,
            'v1', '1000000', 1.000000, 101, 'block-101', :now, 'FINAL', 'SYNTHETIC', :now, :digest,
            'REVIEW', 'UNMATCHED', true, NULL, NULL, NULL
        )
    """), {"now": now, "digest": "a" * 64, "contract": USDT_TRC20_CONTRACT,
          "source_address": SOURCE_ADDRESS, "official_address": OFFICIAL_ADDRESS})
    connection.execute(text("""
        INSERT INTO wallet_manual_deposit_cases (
            id, receipt_id, user_id, binding_id, binding_version, binding_effective_from_block,
            binding_effective_to_block, facts_digest, actor_id, idempotency_key, payload_digest,
            reason_detail_digest, reason_detail, ownership_attestation, created_at
        ) VALUES (
            'case-1', 'receipt-1', 'right-user', 'binding-1', 1, 101, NULL, :digest, 'owner', 'case-key',
            :digest, :digest, 'synthetic reason', true, :now
        )
    """), {"now": now, "digest": "a" * 64})
    return now


def _credit_sql(*, case_id: str | None, user_id: str = "right-user", intent_id: str | None = None) -> str:
    case = "NULL" if case_id is None else f"'{case_id}'"
    intent = "NULL" if intent_id is None else f"'{intent_id}'"
    return (
        "UPDATE wallet_deposit_receipts SET status='CREDITED', pending_obligation=false, "
        f"intent_id={intent}, manual_case_id={case}, user_id='{user_id}', ledger_transaction_id='ledger-1' "
        "WHERE id='receipt-1'"
    )


def test_0066_native_trigger_requires_approved_reciprocal_case(migrated_schema):
    with migrated_schema.begin() as connection:
        _seed(connection)
        connection.execute(text("""
            INSERT INTO wallet_deposit_receipts (
                id, network, contract, txid, log_index, source_address, official_address,
                official_config_version, amount_units, amount, block_number, block_id, block_time,
                evidence_policy, evidence_source, observed_at, facts_digest, status, reason_code,
                pending_obligation, intent_id, user_id, ledger_transaction_id
            ) VALUES (
                'receipt-2', 'TRON', :contract, 'another_txid', 0, :source_address, :official_address,
                'v1', '1000000', 1.000000, 101, 'block-101', CURRENT_TIMESTAMP, 'FINAL', 'SYNTHETIC', CURRENT_TIMESTAMP,
                :digest, 'REVIEW', 'UNMATCHED', true, NULL, NULL, NULL
            )
        """), {"digest": "c" * 64, "contract": USDT_TRC20_CONTRACT,
              "source_address": SOURCE_ADDRESS, "official_address": OFFICIAL_ADDRESS})
        connection.execute(text("""
            INSERT INTO wallet_manual_deposit_cases (
                id, receipt_id, user_id, binding_id, binding_version, binding_effective_from_block,
                binding_effective_to_block, facts_digest, actor_id, idempotency_key, payload_digest,
                reason_detail_digest, reason_detail, ownership_attestation, created_at
            ) VALUES (
                'case-2', 'receipt-2', 'right-user', 'binding-1', 1, 101, NULL, :digest, 'owner', 'case-key-2',
                :digest, :digest, 'different receipt', true, CURRENT_TIMESTAMP
            )
        """), {"digest": "c" * 64})

    # A valid case must still be rejected before its decision exists.
    with pytest.raises(DBAPIError, match="reciprocal approved"):
        with migrated_schema.begin() as connection:
            connection.execute(text(_credit_sql(case_id="case-1")))

    with migrated_schema.begin() as connection:
        for decision_id, case_id in (("decision-1", "case-1"), ("decision-2", "case-2")):
            connection.execute(text("""
                INSERT INTO wallet_manual_deposit_decisions
                    (id, case_id, actor_id, decision, idempotency_key, payload_digest,
                     reason_detail_digest, reason_detail, created_at)
                VALUES (:decision_id, :case_id, 'owner', 'APPROVED', :idempotency_key, :digest,
                        :digest, 'approved synthetic reason', CURRENT_TIMESTAMP)
            """), {"decision_id": decision_id, "case_id": case_id,
                  "idempotency_key": f"{decision_id}-key", "digest": "b" * 64})

    for sql in (
        _credit_sql(case_id="case-1", user_id="wrong-user"),
        _credit_sql(case_id="case-2"),
        _credit_sql(case_id="case-1", intent_id="intent-1"),
        _credit_sql(case_id=None),
    ):
        with pytest.raises(DBAPIError, match="immutable deposit receipt|reciprocal approved"):
            with migrated_schema.begin() as connection:
                connection.execute(text(sql))

    with migrated_schema.begin() as connection:
        connection.execute(text(_credit_sql(case_id="case-1")))

    with migrated_schema.connect() as connection:
        assert connection.execute(text("""
            SELECT status, pending_obligation, intent_id, manual_case_id, user_id, ledger_transaction_id
            FROM wallet_deposit_receipts WHERE id='receipt-1'
        """)).one() == ("CREDITED", False, None, "case-1", "right-user", "ledger-1")

    for sql in (
        "UPDATE wallet_deposit_receipts SET reason_code='TAMPERED' WHERE id='receipt-1'",
        "DELETE FROM wallet_deposit_receipts WHERE id='receipt-1'",
    ):
        with pytest.raises(DBAPIError, match="immutable deposit receipt|history must be retained"):
            with migrated_schema.begin() as connection:
                connection.execute(text(sql))


def test_0066_native_triggers_keep_case_and_decision_append_only(migrated_schema):
    with migrated_schema.begin() as connection:
        _seed(connection)
        connection.execute(text("""
            INSERT INTO wallet_manual_deposit_decisions
                (id, case_id, actor_id, decision, idempotency_key, payload_digest,
                 reason_detail_digest, reason_detail, created_at)
            VALUES ('decision-1', 'case-1', 'owner', 'APPROVED', 'decision-key', :digest,
                    :digest, 'approved synthetic reason', CURRENT_TIMESTAMP)
        """), {"digest": "b" * 64})

    for sql in (
        "UPDATE wallet_manual_deposit_cases SET reason_detail='tampered' WHERE id='case-1'",
        "DELETE FROM wallet_manual_deposit_cases WHERE id='case-1'",
        "UPDATE wallet_manual_deposit_decisions SET decision='REJECTED' WHERE id='decision-1'",
        "DELETE FROM wallet_manual_deposit_decisions WHERE id='decision-1'",
    ):
        with pytest.raises(DBAPIError, match="append-only"):
            with migrated_schema.begin() as connection:
                connection.execute(text(sql))


def test_0066_orm_and_native_trigger_keep_ordinary_receipt_credit_compatible(migrated_schema):
    from app.modules.wallet.receipt_models import DepositReceipt
    from sqlalchemy.orm import Session

    with migrated_schema.begin() as connection:
        _seed(connection)
        connection.execute(text("""
            INSERT INTO wallet_deposit_intents
                (id, user_id, idempotency_key, binding_id, binding_version, binding_effective_from_block,
                 source_address, official_address, official_config_version, network, expected_amount,
                 rules_snapshot, status, created_at, expires_at, closed_at)
            VALUES ('intent-1', 'right-user', 'intent-key', 'binding-1', 1, 101,
                    :source_address, :official_address, 'v1', 'TRON', 10.000000,
                    '{}'::json, 'OPEN', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '5 minutes', NULL)
        """), {"source_address": SOURCE_ADDRESS, "official_address": OFFICIAL_ADDRESS})

    with Session(migrated_schema) as session:
        row = session.get(DepositReceipt, "receipt-1")
        row.status = "CREDITED"
        row.pending_obligation = False
        row.intent_id = "intent-1"
        row.user_id = "right-user"
        row.ledger_transaction_id = "ledger-1"
        session.commit()

    with migrated_schema.connect() as connection:
        assert connection.scalar(text("SELECT manual_case_id FROM wallet_deposit_receipts WHERE id='receipt-1'")) is None


def test_0066_orm_listener_rechecks_reciprocal_approved_case(migrated_schema):
    from app.modules.wallet.receipt_models import DepositReceipt
    from sqlalchemy.orm import Session

    with migrated_schema.begin() as connection:
        _seed(connection)

    with Session(migrated_schema) as session:
        row = session.get(DepositReceipt, "receipt-1")
        row.status = "CREDITED"
        row.pending_obligation = False
        row.manual_case_id = "case-1"
        row.user_id = "right-user"
        row.ledger_transaction_id = "ledger-1"
        with pytest.raises(ValueError, match="reciprocal approved"):
            session.commit()
        session.rollback()

        session.execute(text("""
            INSERT INTO wallet_manual_deposit_decisions
                (id, case_id, actor_id, decision, idempotency_key, payload_digest,
                 reason_detail_digest, reason_detail, created_at)
            VALUES ('decision-1', 'case-1', 'owner', 'APPROVED', 'decision-key', :digest,
                    :digest, 'approved synthetic reason', CURRENT_TIMESTAMP)
        """), {"digest": "b" * 64})
        row = session.get(DepositReceipt, "receipt-1")
        row.status = "CREDITED"
        row.pending_obligation = False
        row.manual_case_id = "case-1"
        row.user_id = "right-user"
        row.ledger_transaction_id = "ledger-1"
        session.commit()
