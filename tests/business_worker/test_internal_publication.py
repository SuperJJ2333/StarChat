from datetime import datetime, timezone
from dataclasses import replace
import hashlib
import json
import ast
import inspect
from contextlib import contextmanager
from decimal import Decimal
from pathlib import Path
from uuid import uuid4
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.exc import OperationalError

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxMessage, OutboxPublisher
from app.modules.audit.models import AuditEvent
from worker import Worker


def factory_components():
    engine = create_engine("sqlite+pysqlite:///:memory:")
    Base.metadata.create_all(engine)
    return engine, create_session_factory(engine)


def handlers(factory):
    import main

    builder = getattr(main, "build_internal_publication_handlers", None)
    assert callable(builder), "production worker has no internal publication consumers"
    return builder(factory)


@pytest.mark.parametrize(
    "topic,event_type,aggregate_type,payload",
    [
        (
            "ledger",
            "manual_reserve.published",
            "manual_reserve",
            {
                "evaluation_id": str(uuid4()),
                "version": 1,
                "source_identity": "b" * 64,
                "observation_id": 1,
                "cut_digest": "a" * 64,
            },
        ),
        (
            "wallet",
            "wallet.funding_scan_discovered",
            "wallet",
            {"id": "global", "reason_code": "FUNDING_SCAN_DISCOVERED"},
        ),
    ],
)
def test_actual_outbox_worker_persists_receipt_before_success(
    topic, event_type, aggregate_type, payload
):
    engine, factory = factory_components()
    now = datetime(2026, 9, 27, tzinfo=timezone.utc)
    with factory.begin() as session:
        original_id = str(uuid4())
        session.add(
            AuditEvent(
                id=original_id,
                actor_id=None,
                subject_type="synthetic_source",
                subject_id="global",
                action="source.committed",
                result="SUCCESS",
                reason_code="SYNTHETIC",
                trace_id="synthetic",
                created_at=now,
            )
        )
        event_id = OutboxPublisher.enqueue(
            session,
            topic=topic,
            event_type=event_type,
            aggregate_type=aggregate_type,
            aggregate_id="global",
            payload=payload,
            now=now,
        )
    worker = Worker(
        consumer=OutboxConsumer(factory, now_factory=lambda: now),
        handlers=handlers(factory),
        worker_id="synthetic-publication-worker",
        now_factory=lambda: now,
    )
    assert worker.run_once() == 1
    with factory() as session:
        assert session.get(OutboxEvent, event_id).status == "PUBLISHED"
        receipts = list(
            session.scalars(
                select(AuditEvent).where(
                    AuditEvent.action == "outbox.internal_published"
                )
            )
        )
        assert len(receipts) == 1
        assert receipts[0].subject_id == event_id
        assert set(receipts[0].after_data) == {
            "receipt_version",
            "topic",
            "event_type",
            "envelope_sha256",
        }
        assert "payload" not in str(receipts[0].after_data)
        assert session.get(AuditEvent, original_id).action == "source.committed"
    engine.dispose()


def test_only_explicit_internal_topics_registered_notification_and_alert_preserved():
    engine, factory = factory_components()
    assert set(handlers(factory)) == {
        "admin",
        "friendship.events",
        "identity",
        "identity.staff",
        "identity.wallet_access",
        "ledger",
        "moments",
        "moments.events",
        "recharge",
        "wallet",
        "wallet.incident",
    }
    assert "notification" not in handlers(factory) and "wallet.alert" not in handlers(
        factory
    )
    engine.dispose()


def message(
    topic="wallet",
    event_type="wallet.funding_scan_discovered",
    aggregate_type="wallet",
    aggregate_id="global",
    payload=None,
):
    return OutboxMessage(
        str(uuid4()),
        topic,
        event_type,
        aggregate_type,
        aggregate_id,
        payload or {"id": "global", "reason_code": "FUNDING_SCAN_DISCOVERED"},
        {},
        1,
    )


_RECOVERY_PUBLICATIONS = [
    ('recharge', 'recharge.owner_taken_over', 'recharge_request',
        {'request_id': 'order', 'status': 'SUBMITTED', 'processing_stage': 'PAYMENT_VERIFIED'}),
    ('wallet', 'wallet.manual_payout_rate_prepared', 'manual_payout_order',
        {'order_id': 'order', 'preparation_version': 1}),
    ('wallet', 'wallet.support_payout_taken_over', 'manual_payout_order',
        {'order_id': 'order', 'actor_id': 'owner', 'previous_actor_id': 'support',
            'reason_code': 'SHIFT_HANDOFF', 'evidence_only': True}),
    ('wallet', 'wallet.support_payout_rejected', 'manual_payout_order',
        {'order_id': 'order', 'actor_id': 'support', 'reason_code': 'PAYOUT_ADDRESS_INVALID'}),
    ('wallet', 'wallet.manual_payout_locator_submitted', 'manual_payout_order',
        {'order_id': 'order', 'actor_id': 'support', 'reason_code': 'INITIAL_LOCATOR'}),
    ('wallet', 'wallet.manual_payout_locator_corrected', 'manual_payout_order',
        {'order_id': 'order', 'actor_id': 'support', 'reason_code': 'DISCOVERED_LOCATOR_SELECTED'}),
]
for _event, _reason in [
    ('support_payout_address_read', 'SUPPORT_PAYOUT_ADDRESS_READ'),
    ('support_payout_discovery_read', 'SUPPORT_PAYOUT_DISCOVERY_READ'),
    ('support_payout_discovery_ambiguous', 'ORDER_ATTRIBUTION_AMBIGUOUS'),
    ('manual_payout_prepare_rate', 'MANUAL_PAYOUT_RATE_PREPARED'),
    ('manual_payout_support_claim', 'MANUAL_PAYOUT_SUPPORT_CLAIM'),
    ('manual_payout_support_review_claim', 'SHIFT_HANDOFF'),
    ('manual_payout_support_takeover', 'SHIFT_HANDOFF'),
    ('manual_payout_support_select', 'DISCOVERED_LOCATOR_SELECTED'),
    ('manual_payout_support_reject', 'PAYOUT_ADDRESS_INVALID'),
    ('manual_payout_void_unbroadcast', 'INCIDENT_REVIEW'),
    ('manual_payout_claim', 'MANUAL_PAYOUT_CLAIM'),
    ('manual_payout_submit_txid', 'MANUAL_PAYOUT_SUBMIT_TXID'),
    ('manual_payout_correct_candidate', 'DISCOVERED_LOCATOR_SELECTED'),
    ('manual_payout_adjust_rate', 'MANUAL_PAYOUT_RATE_ADJUSTED'),
]:
    _RECOVERY_PUBLICATIONS.append(('wallet', 'wallet.' + _event, 'wallet',
        {'id': 'order', 'reason_code': _reason}))


@pytest.mark.parametrize('topic,event,aggregate,payload', _RECOVERY_PUBLICATIONS)
def test_recovery_publications_accept_exact_contract_and_reject_sensitive_fields(
        topic, event, aggregate, payload):
    from tasks.internal_publication import InternalPublicationTask
    published = []
    task = InternalPublicationTask(SimpleNamespace(record_internal_publication=lambda **kw: published.append(kw)))
    item = message(topic, event, aggregate, 'order', payload)
    task(item)
    assert len(published) == 1 and 'envelope_sha256' in published[0]
    assert set(published[0]) == {'event_id', 'topic', 'event_type', 'envelope_sha256'}
    for field in ('full_address', 'claim_token', 'recipient_id'):
        with pytest.raises(ValueError, match='INVALID_INTERNAL_PUBLICATION'):
            task(replace(item, payload=dict(payload, **{field: 'secret'})))
    with pytest.raises(ValueError, match='INVALID_INTERNAL_PUBLICATION'):
        task(replace(item, aggregate_id='another-order'))
    with pytest.raises(ValueError, match='INVALID_INTERNAL_PUBLICATION'):
        task(replace(item, headers={'recipient_id': 'owner'}))
    assert len(published) == 1


@pytest.mark.parametrize(
    "topic,event_type,aggregate,payload",
    [
        (
            "admin",
            "admin.ban.created",
            "admin_ban",
            {"subject_type": "user", "subject_id": "synthetic"},
        ),
        (
            "friendship.events",
            "friend.requested",
            "friendship",
            {"actor_id": "synthetic"},
        ),
        (
            "identity",
            "payment_pin.configured",
            "payment_pin",
            {"user_id": "synthetic", "result": "SUCCESS"},
        ),
        (
            "identity.staff",
            "identity.staff.activated",
            "user",
            {"user_id": "synthetic"},
        ),
        (
            "identity.wallet_access",
            "identity.wallet_access.verified",
            "wallet_access_grant",
            {"grant_id": "synthetic", "scope": "wallet-admin", "auth_mode": "totp"},
        ),
        (
            "ledger",
            "ledger.posted",
            "ledger_transaction",
            {"transaction_id": "synthetic", "asset": "CAIBI"},
        ),
        ("moments", "native_ad.created", "native_moment_ad", {"status": "DRAFT"}),
        ("moments.events", "moment.liked", "moment", {"actor_id": "synthetic"}),
        (
            "recharge",
            "recharge.submitted",
            "recharge_request",
            {"request_id": "synthetic", "user_id": "synthetic"},
        ),
        (
            "wallet",
            "wallet.daily_closed",
            "wallet",
            {"id": "synthetic", "reason_code": "SYNTHETIC"},
        ),
        (
            "wallet.incident",
            "wallet.incident.opened",
            "wallet_incident",
            {
                "incident_id": "synthetic",
                "subject_id": "global",
                "code": "SYNTHETIC",
                "severity": "P0",
            },
        ),
    ],
)
def test_typed_representative_for_all_eleven_domains(
    topic, event_type, aggregate, payload
):
    engine, factory = factory_components()
    item = message(topic, event_type, aggregate, "synthetic", payload)
    handlers(factory)[topic](item)
    with factory() as session:
        rows = list(session.scalars(select(AuditEvent)))
        assert len(rows) == 1 and rows[0].after_data["topic"] == topic
    engine.dispose()


@pytest.mark.parametrize("severity", ["P0", "P1", "T2"])
@pytest.mark.parametrize(
    "event_type", ["wallet.incident.opened", "wallet.incident.severity_changed"]
)
def test_wallet_incident_internal_publication_preserves_literal_severity(
    event_type, severity
):
    from app.modules.audit.writer import AuditWriter
    from tasks.internal_publication import InternalPublicationTask

    engine, factory = factory_components()
    item = message(
        "wallet.incident",
        event_type,
        "wallet_incident",
        "incident-1",
        {
            "incident_id": "incident-1",
            "subject_id": "global",
            "code": "MANUAL_SOURCE_UNAVAILABLE",
            "severity": severity,
        },
    )
    task = InternalPublicationTask(AuditWriter(factory))
    task(item)
    task(item)
    with factory() as session:
        receipts = list(
            session.scalars(
                select(AuditEvent).where(
                    AuditEvent.action == "outbox.internal_published"
                )
            )
        )
        assert len(receipts) == 1
        assert receipts[0].subject_id == item.id
        assert receipts[0].after_data["event_type"] == event_type
        assert "payload" not in receipts[0].after_data
    engine.dispose()


def test_source_timeout_reclassification_publication_accepts_only_t2():
    from app.modules.audit.writer import AuditWriter
    from tasks.internal_publication import InternalPublicationTask

    engine, factory = factory_components()
    task = InternalPublicationTask(AuditWriter(factory))
    payload = {
        "incident_id": "incident-1",
        "subject_id": "global",
        "code": "MANUAL_SOURCE_UNAVAILABLE",
        "severity": "T2",
    }
    item = message(
        "wallet.incident", "wallet.incident.source_timeout_reclassified",
        "wallet_incident", "incident-1", payload,
    )
    task(item)
    for severity in ("P0", "P1", "P2"):
        with pytest.raises(ValueError, match="^INVALID_INTERNAL_PUBLICATION$"):
            task(replace(item, payload=dict(payload, severity=severity)))
    with factory() as session:
        receipts = list(session.scalars(select(AuditEvent).where(
            AuditEvent.action == "outbox.internal_published")))
        assert len(receipts) == 1
        assert receipts[0].subject_id == item.id
    engine.dispose()


@pytest.mark.parametrize(
    "changes",
    [
        {"topic": "notification"},
        {"event_type": "wallet.execute_anything"},
        {"aggregate_type": "different"},
        {"headers": {"token": "synthetic"}},
        {
            "payload": {
                "id": "global",
                "reason_code": "FUNDING_SCAN_DISCOVERED",
                "extra": True,
            }
        },
        {"payload": {"id": "other", "reason_code": "FUNDING_SCAN_DISCOVERED"}},
        {"id": "not-an-event-id"},
        {"topic": []},
        {"event_type": []},
        {"aggregate_type": []},
    ],
)
def test_invalid_envelope_never_records_or_delivers(changes):
    engine, factory = factory_components()
    with pytest.raises(ValueError, match="^INVALID_INTERNAL_PUBLICATION$"):
        handlers(factory)["wallet"](replace(message(), **changes))
    with factory() as session:
        assert list(session.scalars(select(AuditEvent))) == []
    engine.dispose()


def test_full_canonical_envelope_hash_ignores_attempt_and_dict_order_only():
    engine, factory = factory_components()
    item = message()
    task = handlers(factory)["wallet"]
    task(item)
    task(
        replace(
            item, attempt_count=9, payload=dict(reversed(list(item.payload.items())))
        )
    )
    stable = {
        "id": item.id,
        "topic": item.topic,
        "event_type": item.event_type,
        "aggregate_type": item.aggregate_type,
        "aggregate_id": item.aggregate_id,
        "payload": item.payload,
        "headers": item.headers,
    }
    expected = hashlib.sha256(
        json.dumps(
            stable, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode()
    ).hexdigest()
    with factory() as session:
        rows = list(session.scalars(select(AuditEvent)))
        assert len(rows) == 1 and rows[0].after_data["envelope_sha256"] == expected
    engine.dispose()


def test_lost_ack_reclaim_keeps_one_receipt_and_historical_dead_untouched():
    engine, factory = factory_components()
    now = datetime(2026, 9, 27, tzinfo=timezone.utc)
    with factory.begin() as session:
        ids = [
            OutboxPublisher.enqueue(
                session,
                topic="wallet",
                event_type="wallet.funding_scan_discovered",
                aggregate_type="wallet",
                aggregate_id="global",
                payload={"id": "global", "reason_code": "FUNDING_SCAN_DISCOVERED"},
                now=now,
            )
            for _ in range(2)
        ]
        session.flush()
        session.get(OutboxEvent, ids[1]).status = "DEAD"
    consumer = OutboxConsumer(factory, now_factory=lambda: now)
    first = consumer.claim_batch(worker_id="lost-ack", limit=1, topics=["wallet"])[0]
    handlers(factory)["wallet"](first)
    from datetime import timedelta

    later = now + timedelta(minutes=6)
    retry_consumer = OutboxConsumer(factory, now_factory=lambda: later)
    worker = Worker(
        consumer=retry_consumer,
        handlers=handlers(factory),
        worker_id="retry",
        now_factory=lambda: later,
    )
    assert worker.run_once() == 1
    with factory() as session:
        assert len(list(session.scalars(select(AuditEvent)))) == 1
        assert session.get(OutboxEvent, ids[0]).status == "PUBLISHED"
        assert session.get(OutboxEvent, ids[1]).status == "DEAD"
    engine.dispose()


def test_current_literal_producer_contracts_are_explicitly_consumed():
    from tasks.internal_publication import CATALOG
    from app.modules.audit.writer import INTERNAL_PUBLICATION_TOPICS

    missing = []
    paths = list(Path("services/business-api/app").rglob("*.py"))
    assert paths, "the producer source inventory must not be empty"
    for path in paths:
        for node in ast.walk(ast.parse(path.read_text("utf8"))):
            if not isinstance(node, ast.Call):
                continue
            if ast.unparse(node.func) == "OutboxPublisher.enqueue":
                fields = {k.arg: k.value for k in node.keywords}
                names = ("topic", "event_type", "aggregate_type")
                if all(isinstance(fields.get(k), ast.Constant) for k in names):
                    key = tuple(fields[k].value for k in names)
                    if key[0] in INTERNAL_PUBLICATION_TOPICS and key not in CATALOG:
                        missing.append((path.name, node.lineno, key))
            if ast.unparse(node.func) == "audit_write" and len(node.args) > 3:
                action = node.args[3]
                if (
                    isinstance(action, ast.Constant)
                    and ("wallet", action.value, "wallet") not in CATALOG
                ):
                    missing.append((path.name, node.lineno, action.value))
    assert missing == []


def test_friendship_inherited_audit_caller_closure_is_explicitly_consumed():
    from app.modules.friendship.service import FriendshipService
    from tasks.internal_publication import CATALOG

    classes = [cls for cls in FriendshipService.__mro__ if cls is not object]
    assert {cls.__name__ for cls in classes} >= {
        "FriendshipService",
        "DirectRoomRecovery",
        "DirectConversationLifecycle",
    }
    callers = []
    for cls in classes:
        path = Path(inspect.getfile(cls))
        source = path.read_text("utf8")
        assert source, "inherited producer source must not be empty"
        tree = ast.parse(source)
        definition = next(
            node
            for node in tree.body
            if isinstance(node, ast.ClassDef) and node.name == cls.__name__
        )
        for method in definition.body:
            if not isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            for node in ast.walk(method):
                if (
                    not isinstance(node, ast.Call)
                    or ast.unparse(node.func) != "self._audit"
                ):
                    continue
                assert len(node.args) == 6 and not node.keywords
                action = node.args[3]
                assert isinstance(action, ast.Constant) and isinstance(
                    action.value, str
                )
                callers.append((cls.__name__, method.name, action.value))
                assert ("friendship.events", action.value, "friendship") in CATALOG
    assert len(callers) >= 22
    assert {action for _, _, action in callers} >= {
        "friend.direct_room_associated",
        "friend.direct_room_recoverable",
        "friend.direct_room_recovered",
        "friend.direct_room_generation_reserved",
    }
    wrapper = next(
        node
        for node in ast.parse(inspect.getsource(FriendshipService)).body[0].body
        if isinstance(node, ast.FunctionDef) and node.name == "_audit"
    )
    producer = next(
        node
        for node in ast.walk(wrapper)
        if isinstance(node, ast.Call)
        and ast.unparse(node.func) == "OutboxPublisher.enqueue"
    )
    fields = {keyword.arg: keyword.value for keyword in producer.keywords}
    assert ast.literal_eval(fields["topic"]) == "friendship.events"
    assert ast.literal_eval(fields["aggregate_type"]) == "friendship"
    assert ast.unparse(fields["event_type"]) == "action"
    assert ast.unparse(fields["aggregate_id"]) == "subject"
    assert ast.unparse(fields["payload"]) == "{'actor_id': actor}"


@pytest.mark.parametrize(
    "event_type",
    [
        "friend.direct_room_associated",
        "friend.direct_room_recoverable",
        "friend.direct_room_recovered",
        "friend.direct_room_generation_reserved",
    ],
)
def test_real_inherited_friendship_producer_gets_durable_receipt(event_type):
    from app.modules.friendship.models import DirectConversation, Friendship
    from app.modules.friendship.service import FriendshipService
    from app.modules.identity.models import User
    from app.modules.identity.enums import AccountStatus

    engine, factory = factory_components()
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user in ("alice", "bob"):
            session.add(
                User(
                    id=user,
                    username=user,
                    username_normalized=user,
                    email=f"{user}@example.test",
                    email_normalized=f"{user}@example.test",
                    password_hash="synthetic",
                    status=AccountStatus.ACTIVE,
                    created_at=now,
                    updated_at=now,
                )
            )
        session.add(
            Friendship(
                id=str(uuid4()), user_low_id="alice", user_high_id="bob", created_at=now
            )
        )

    class Metadata:
        marker = None

        def get_room_state(self, room):
            return self.get_room_state_strict(room)

        def get_room_state_strict(self, room):
            if room == "!retired:example.test":
                return []
            return [
                {
                    "type": "m.room.encryption",
                    "state_key": "",
                    "content": {"algorithm": "m.megolm.v1.aes-sha2"},
                },
                *[
                    {
                        "type": "m.room.member",
                        "state_key": f"@{user}:example.test",
                        "content": {"membership": "join"},
                    }
                    for user in ("alice", "bob")
                ],
                {
                    "type": "com.chatflow.direct_reservation",
                    "state_key": "",
                    "content": {"reservation_id": self.marker},
                },
            ]

        def get_room_details(self, room):
            return {"room_id": room, "joined_members": 0}

        def resolve_room_alias(self, alias):
            return "!verified:example.test"

    profiles = SimpleNamespace(
        read_public_profiles=lambda ids: {
            user: SimpleNamespace(matrix_user_id=f"@{user}:example.test")
            for user in ids
        }
    )
    metadata = Metadata()
    service = FriendshipService(
        factory, profiles, matrix_gateway=metadata, matrix_server_name="example.test"
    )
    if event_type == "friend.direct_room_generation_reserved":
        with factory.begin() as session:
            session.add(
                DirectConversation(
                    id=str(uuid4()),
                    user_low_id="alice",
                    user_high_id="bob",
                    matrix_room_id="!retired:example.test",
                    created_at=now,
                )
            )
        reply = service.resolve_direct_conversation("alice", "bob", str(uuid4()))
        assert reply["status"] == "create_required" and reply["generation"] == 1
    else:
        claim = service.claim_direct_conversation_v2("alice", "bob", str(uuid4()))
        metadata.marker = claim["reservation_id"]
        assert (
            service.recover_direct_conversation(
                "alice", "bob", str(uuid4()), "!verified:example.test"
            )["matrix_room_id"]
            == "!verified:example.test"
        )

    with factory() as session:
        events = list(session.scalars(select(OutboxEvent)))
        assert event_type in {event.event_type for event in events}
        assert all(event.payload == {"actor_id": "alice"} for event in events)
        original_audit = [
            (row.id, row.action) for row in session.scalars(select(AuditEvent))
        ]
    tables = [
        table
        for name, table in Base.metadata.tables.items()
        if name.startswith(("direct_", "friendship", "users"))
    ]

    def snapshot():
        with engine.connect() as connection:
            return {
                table.name: [tuple(row) for row in connection.execute(select(table))]
                for table in tables
            }

    before = snapshot()
    worker = Worker(
        consumer=OutboxConsumer(factory),
        handlers=handlers(factory),
        worker_id="synthetic-friendship-publication",
    )
    assert worker.run_once() == len(events)
    with factory() as session:
        assert all(
            row.status == "PUBLISHED" for row in session.scalars(select(OutboxEvent))
        )
        receipts = list(
            session.scalars(
                select(AuditEvent).where(
                    AuditEvent.action == "outbox.internal_published"
                )
            )
        )
        assert len(receipts) == len(events)
        assert {row.subject_id for row in receipts} == {event.id for event in events}
        assert all(
            set(row.after_data)
            == {"receipt_version", "topic", "event_type", "envelope_sha256"}
            for row in receipts
        )
        assert [
            (row.id, row.action)
            for row in session.scalars(select(AuditEvent))
            if row.action != "outbox.internal_published"
        ] == original_audit
    assert snapshot() == before
    engine.dispose()


@pytest.mark.parametrize(
    "event_type",
    [
        "friend.direct_room_associated",
        "friend.direct_room_recoverable",
        "friend.direct_room_recovered",
        "friend.direct_room_generation_reserved",
    ],
)
@pytest.mark.parametrize(
    "changes",
    [
        {"payload": {}},
        {"payload": {"actor_id": "alice", "extra": True}},
        {"payload": {"actor_id": ""}},
        {"payload": {"actor_id": False}},
        {"payload": {"actor_id": "a" * 129}},
        {"aggregate_type": "direct_conversation"},
        {"aggregate_id": ""},
        {"headers": {"unknown": True}},
        {"event_type": "friend.direct_room_unknown"},
    ],
)
def test_inherited_friendship_contract_keeps_invalid_envelopes_closed(
    event_type, changes
):
    engine, factory = factory_components()
    item = message(
        "friendship.events",
        event_type,
        "friendship",
        "synthetic-subject",
        {"actor_id": "alice"},
    )
    with pytest.raises(ValueError, match="^INVALID_INTERNAL_PUBLICATION$"):
        handlers(factory)["friendship.events"](replace(item, **changes))
    with factory() as session:
        assert list(session.scalars(select(AuditEvent))) == []
    engine.dispose()


def test_receipt_commit_failure_does_not_ack_and_keeps_closed_error():
    from app.modules.audit.writer import AuditWriter
    from tasks.internal_publication import InternalPublicationTask

    engine, factory = factory_components()
    now = datetime(2026, 9, 27, tzinfo=timezone.utc)
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session,
            topic="wallet",
            event_type="wallet.funding_scan_discovered",
            aggregate_type="wallet",
            aggregate_id="global",
            payload={"id": "global", "reason_code": "FUNDING_SCAN_DISCOVERED"},
            now=now,
        )

    class CommitFailure:
        @contextmanager
        def begin(self):
            with factory.begin() as session:
                yield session
                raise OperationalError("synthetic secret SQL", {}, Exception("secret"))

    worker = Worker(
        consumer=OutboxConsumer(factory, now_factory=lambda: now),
        handlers={"wallet": InternalPublicationTask(AuditWriter(CommitFailure()))},
        worker_id="synthetic-failure",
        now_factory=lambda: now,
    )
    assert worker.run_once() == 1
    with factory() as session:
        row = session.get(OutboxEvent, event_id)
        assert row.status == "FAILED" and row.published_at is None
        assert row.last_error == "INTERNAL_PUBLICATION_STORAGE_FAILURE"
        assert list(session.scalars(select(AuditEvent))) == []
    engine.dispose()


def test_real_ledger_publication_changes_only_receipt_and_outbox_ack():
    from app.modules.ledger.service import LedgerService
    from app.modules.wallet.models import WalletControl

    engine, factory = factory_components()
    # Real public producer applies the balanced ledger transaction first.
    LedgerService(factory).adjust(
        user_id="synthetic-user",
        amount=Decimal("12.34"),
        actor_id="synthetic-finance",
        reason_code="SYNTHETIC_SEED",
        idempotency_key="synthetic-seed",
    )
    with factory.begin() as session:
        session.add(
            WalletControl(
                id="global", withdrawals_paused=True, pause_reason="SYNTHETIC_PAUSE"
            )
        )

    def financial_snapshot():
        with engine.connect() as conn:
            return {
                table.name: [tuple(row) for row in conn.execute(select(table))]
                for table in sorted(
                    Base.metadata.tables.values(), key=lambda table: table.name
                )
                if table.name.startswith(("ledger_", "wallet_"))
            }

    before = financial_snapshot()
    with factory() as session:
        original_audit = [
            (row.id, row.action, row.after_data)
            for row in session.scalars(select(AuditEvent))
        ]
    worker = Worker(
        consumer=OutboxConsumer(factory),
        handlers=handlers(factory),
        worker_id="synthetic-ledger",
    )
    assert worker.run_once() == 1
    assert financial_snapshot() == before
    assert LedgerService(factory).balance("synthetic-user") == Decimal("12.34")
    with factory() as session:
        assert [
            (row.id, row.action, row.after_data)
            for row in session.scalars(select(AuditEvent))
            if row.action != "outbox.internal_published"
        ] == original_audit
    engine.dispose()
