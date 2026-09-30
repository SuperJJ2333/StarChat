"""Strict internal fact publication; no external delivery or financial replay.

Every catalog entry below names a current producer contract. Unknown historical
facts remain failures for operator review instead of being acknowledged blindly.
"""

import hashlib
import json
import re
from uuid import UUID

from app.core.outbox import OutboxMessage
from app.modules.audit.writer import AuditWriter, INTERNAL_PUBLICATION_TOPICS


def _uuid(value):
    try:
        return isinstance(value, str) and str(UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def _text(value):
    return isinstance(value, str) and 0 < len(value) <= 128


def _reason(value):
    return isinstance(value, str) and 0 < len(value) <= 256


def _integer(value):
    return type(value) is int and 0 <= value <= 2**63 - 1


def _positive(value):
    return _integer(value) and value > 0


def _boolean(value):
    return type(value) is bool


def _hash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _amount(value):
    return (
        isinstance(value, str)
        and re.fullmatch(r"[0-9]{1,24}(?:\.[0-9]{1,6})?", value) is not None
    )


def _one(*values):
    return lambda value: isinstance(value, str) and value in values


def _nullable(validator):
    return lambda value: value is None or validator(value)


def _object(fields):
    return lambda value: (
        type(value) is dict
        and set(value) == set(fields)
        and all(check(value[key]) for key, check in fields.items())
    )


# (topic, event_type, aggregate_type) -> (exact payload validator, optional
# payload field bound to aggregate_id). Multiple aggregate types are deliberate:
# some producers emit both their general audit fact and specific domain fact.
CATALOG = {}


def _add(topic, types, aggregate, fields, bound=None):
    for event_type in types.split():
        key = (topic, event_type, aggregate)
        if key in CATALOG:
            raise RuntimeError("DUPLICATE_INTERNAL_PUBLICATION_CONTRACT")
        CATALOG[key] = (_object(fields), bound)


_add(
    "admin",
    "admin.ban.created admin.ban.revoked",
    "admin_ban",
    {"subject_type": _text, "subject_id": _text},
)
_add(
    "admin", "admin.support_role.assigned", "user", {"role_code": _text, "badge": _text}
)
_add("admin", "admin.support_role.revoked", "user", {"role_code": _text})
_add(
    "admin",
    "admin.support_roles.revoked",
    "user",
    {"roles": lambda v: type(v) is list and len(v) <= 100 and all(_text(x) for x in v)},
)
_add(
    "friendship.events",
    """friend.request.updated friend.requested friend.accepted.merged
     friend.accepted friend.rejected friend.request.cancelled friend.blocked friend.unblocked
     friend.tag_created friend.tag_deleted friend.tag_renamed friend.profile_updated friend.deleted
     friend.direct_room_registered friend.direct_room_claimed friend.direct_room_published""",
    "friendship",
    {"actor_id": _text},
)
_add(
    "friendship.events",
    """friend.direct_room_associated friend.direct_room_recoverable
     friend.direct_room_recovered friend.direct_room_generation_reserved""",
    "friendship",
    {"actor_id": _text},
)
_room = _object({"matrix_room_id": _nullable(_reason)})
_repair_room = _object(
    {"matrix_room_id": _reason, "user_low_id": _text, "user_high_id": _text}
)
_add(
    "friendship.events",
    "friend.direct_room_auto_recovered",
    "friendship",
    {
        "operator_id": _one("system:direct-recovery"),
        "trigger_user_id": _text,
        "before": _room,
        "after": _room,
        "reason_code": _one("DIRECT_ROOM_AUTO_RECOVERY"),
    },
)
_add(
    "friendship.events",
    "friend.direct_room_repaired",
    "friendship",
    {
        "operator_id": _text,
        "before": _repair_room,
        "after": _repair_room,
        "reason_code": _reason,
        "idempotency_key": _text,
    },
)
_add(
    "identity",
    "payment_pin.configured payment_pin.authorized payment_pin.consumed",
    "payment_pin",
    {"user_id": _text, "result": _one("SUCCESS")},
    "user_id",
)
_add(
    "identity",
    "payment_pin.verification_failed",
    "payment_pin",
    {"user_id": _text, "result": _one("FAILURE")},
    "user_id",
)
_add(
    "identity",
    """identity.totp.setup_reauthenticated identity.totp.enrolled
     identity.totp.enabled identity.totp.pending_aborted""",
    "totp_credential",
    {"user_id": _text, "credential_id": _text},
    "credential_id",
)
_add(
    "identity.staff", "identity.staff.activated", "user", {"user_id": _text}, "user_id"
)
_add(
    "identity.wallet_access",
    "identity.wallet_access.verified identity.wallet_access.revoked",
    "wallet_access_grant",
    {
        "grant_id": _text,
        "scope": _one("wallet-admin", "support-orders"),
        "auth_mode": _one("totp", "operation_password"),
    },
    "grant_id",
)
_add(
    "ledger",
    "manual_reserve.published",
    "manual_reserve",
    {
        "evaluation_id": _uuid,
        "version": _positive,
        "source_identity": _hash,
        "observation_id": _positive,
        "cut_digest": _hash,
    },
)
_add(
    "ledger",
    "ledger.posted",
    "ledger_transaction",
    {"transaction_id": _text, "asset": _one("CAIBI")},
    "transaction_id",
)
_add(
    "ledger",
    "ledger.outgoing_restricted ledger.manual_restriction_released",
    "ledger_reserve",
    {"scope": _text, "active": _boolean, "epoch": _positive},
)
_history_fields = {
    "ledger_entries": _integer,
    "ledger_transactions": _integer,
    "ledger_restrictions": _integer,
    "reserve": _integer,
}
_history_empty = _object(_history_fields)
_history_full = _object(
    dict(
        _history_fields,
        history_policy=_one("CAIBI_HISTORY_V1"),
        history_digest=_hash,
        caibi_liability=_amount,
    )
)
_add(
    "ledger",
    "ledger.legacy_stop_adopted",
    "ledger_reserve",
    {
        "manifest_digest": _hash,
        "successor_scope": _one("manual_tron"),
        "epoch": _positive,
        "funds_paused": lambda v: v is True,
        "history": lambda v: _history_empty(v) or _history_full(v),
    },
)
_add("moments", "native_ad.created", "native_moment_ad", {"status": _one("DRAFT")})
_add(
    "moments",
    "native_ad.schedule.changed",
    "native_ad_campaign",
    {"ad_id": _text, "status": _one("SCHEDULED", "ACTIVE")},
)
_add(
    "moments.events",
    """moment.published moment.visibility.updated moment.deleted
     moment.liked moment.unliked moment.commented moment.comment_deleted moment.draft_saved
     moment.cover_updated moment.reported""",
    "moment",
    {"actor_id": _text},
)

_add(
    "recharge",
    "recharge.submitted",
    "recharge_request",
    {"request_id": _text, "user_id": _text},
    "request_id",
)
_add(
    "recharge",
    "recharge.cancelled recharge.rejected",
    "recharge_request",
    {"request_id": _text},
    "request_id",
)
_add(
    "recharge",
    "recharge.credited",
    "recharge_request",
    {"request_id": _text, "user_id": _text, "final_caibi_amount": _amount},
    "request_id",
)
_add(
    "recharge",
    "recharge.directory_updated",
    "cs_directory_entry",
    {"entry_id": _text, "enabled": _boolean},
    "entry_id",
)
_add(
    "recharge",
    "recharge.adjustment_submitted",
    "recharge_request",
    {"request_id": _text, "adjustment_id": _text},
    "request_id",
)
_add(
    "recharge",
    "recharge.adjustment_reviewed",
    "adjustment_request",
    {
        "adjustment_id": _text,
        "decision": _one("APPROVED", "REJECTED"),
        "reviewer_id": _text,
    },
    "adjustment_id",
)
_add(
    "recharge",
    "recharge.direct_settlement_executed",
    "recharge_request",
    {"request_id": _text, "adjustment_id": _text, "ledger_transaction_id": _text},
    "request_id",
)
_add(
    "recharge",
    "recharge.bound",
    "recharge_credit_binding",
    {"request_id": _text, "adjustment_id": _text},
)
_add(
    "recharge",
    "recharge.binding_released",
    "recharge_credit_binding",
    {
        "request_id": _text,
        "evidence": _one("ADJUSTMENT_REJECTED", "ADJUSTMENT_REVERSED"),
    },
)
for _state in ("REGISTERED", "NEEDS_REVIEW", "FAILED"):
    _add(
        "recharge",
        "recharge.binding_" + _state.lower(),
        "recharge_credit_binding",
        {"request_id": _text, "state": _one(_state), "reason": _nullable(_reason)},
    )
_add(
    "recharge",
    """recharge.review_claimed recharge.claimed recharge.evidence_submitted
     recharge.payment_verified recharge.settlement_submitted recharge.settlement_executed recharge.expired
     recharge.owner_taken_over""",
    "recharge_request",
    {
        "request_id": _text,
        "status": _one("SUBMITTED", "CREDITED", "REJECTED", "CANCELLED"),
        "processing_stage": _one(
            "SUBMITTED",
            "WAITING_PAYMENT",
            "VERIFYING_PAYMENT",
            "PAYMENT_VERIFIED",
            "REVIEWING",
            "NEEDS_REVIEW",
            "CREDITED",
            "REJECTED",
            "CANCELLED",
        ),
    },
    "request_id",
)

# These and only these actions flow through wallet.safety.audit_write, whose
# payload is exactly id/reason_code. Domain-specific publishers below differ.
_payout_reason = lambda value: isinstance(value, str) and re.fullmatch(r"[A-Z][A-Z0-9_]{2,79}", value) is not None
_payout_rejection = _one("PAYOUT_ADDRESS_INVALID", "PAYOUT_DETAILS_MISMATCH", "PAYOUT_POLICY_INELIGIBLE")
# Internal receipts do not deliver notifications. Exact fields and empty headers
# exclude addresses, claim tokens and recipient routing from these envelopes.
for _action, _validator in (
    ("support_payout_address_read", _one("SUPPORT_PAYOUT_ADDRESS_READ")),
    ("support_payout_discovery_read", _one("SUPPORT_PAYOUT_DISCOVERY_READ")),
    ("support_payout_discovery_ambiguous", _one("ORDER_ATTRIBUTION_AMBIGUOUS")),
    ("manual_payout_prepare_rate", _one("MANUAL_PAYOUT_RATE_PREPARED")),
    ("manual_payout_support_claim", _one("MANUAL_PAYOUT_SUPPORT_CLAIM")),
    ("manual_payout_support_review_claim", _payout_reason),
    ("manual_payout_support_takeover", _payout_reason),
    ("manual_payout_support_select", _one("DISCOVERED_LOCATOR_SELECTED")),
    ("manual_payout_support_reject", _payout_rejection),
    ("manual_payout_void_unbroadcast", _payout_reason),
    ("manual_payout_claim", _one("MANUAL_PAYOUT_CLAIM")),
    ("manual_payout_submit_txid", _one("MANUAL_PAYOUT_SUBMIT_TXID")),
    ("manual_payout_correct_candidate", _payout_reason),
    ("manual_payout_adjust_rate", _one("MANUAL_PAYOUT_RATE_ADJUSTED")),
):
    _add("wallet", "wallet." + _action, "wallet", {"id": _text, "reason_code": _validator}, "id")
_add("wallet", "wallet.manual_payout_rate_prepared", "manual_payout_order",
    {"order_id": _text, "preparation_version": _positive}, "order_id")
_add("wallet", "wallet.support_payout_taken_over", "manual_payout_order",
    {"order_id": _text, "actor_id": _text, "previous_actor_id": _nullable(_text),
        "reason_code": _payout_reason, "evidence_only": _boolean}, "order_id")
_add("wallet", "wallet.support_payout_rejected", "manual_payout_order",
    {"order_id": _text, "actor_id": _text, "reason_code": _payout_rejection}, "order_id")
_add("wallet", "wallet.manual_payout_locator_submitted", "manual_payout_order",
    {"order_id": _text, "actor_id": _text, "reason_code": _one("INITIAL_LOCATOR")}, "order_id")
_add("wallet", "wallet.manual_payout_locator_corrected", "manual_payout_order",
    {"order_id": _text, "actor_id": _text, "reason_code": _payout_reason}, "order_id")
_add(
    "wallet",
    """wallet.binding_register wallet.binding_challenge wallet.binding_confirm wallet.binding_activated
     wallet.daily_closed wallet.converted wallet.conversion_reversed wallet.deposit_intent_closed
     wallet.deposit_intent_created wallet.coverage.conflict wallet.coverage.discovered wallet.coverage.verified
     wallet.funding_scan_processed wallet.funding_scan_retry wallet.manual_deposit_case.created
     wallet.manual_deposit_case.decided wallet.manual_deposit_case.previewed wallet.manual_deposit_case.executed
     wallet.manual_payout_quote wallet.manual_payout_request wallet.manual_payout_cancel wallet.manual_payout_settled
     wallet.manual_payout_review wallet.owner_transfer_declared wallet.deposit_receipt_conflict wallet.deposit_receipt_recorded
     wallet.payout_reconciliation.previewed wallet.payout_reconciliation.submitted wallet.deposit_repair.candidates_viewed
     wallet.deposit_repair.previewed wallet.deposit_repair.executed wallet.restricted wallet.reserve_observed
     wallet.cancelled wallet.report_read wallet.ledger_posted wallet.withdrawal_finalized wallet.withdrawal_requested
     wallet.withdrawal_approved wallet.submitting wallet.paused wallet.deposit_manual_review wallet.withdrawal_unknown
     wallet.provider_submitted wallet.support_payout_expired wallet.support_payout_started wallet.support_payout_heartbeat""",
    "wallet",
    {"id": _text, "reason_code": _reason},
    "id",
)
_add(
    "wallet",
    "wallet.funding_scan_discovered",
    "wallet",
    {"id": _one("global"), "reason_code": _one("FUNDING_SCAN_DISCOVERED")},
    "id",
)
_add(
    "wallet",
    "outbox.handover_notice_delivered",
    "outbox_handover",
    {"manifest_digest": _hash, "alert_count": _positive},
)
_conversion_fields = {
    "receipt_id": _text,
    "original_ledger_transaction_id": _text,
    "conversion_id": _text,
    "wallet_ledger_transaction_id": _text,
    "caibi_ledger_transaction_id": _text,
    "source_amount": _amount,
    "target_amount": _amount,
    "remainder": _amount,
}
_conversion = _object(_conversion_fields)
_add(
    "wallet",
    "wallet.deposit_auto_converted",
    "wallet_receipt",
    _conversion_fields,
    "receipt_id",
)
_add(
    "wallet",
    "wallet.handover.prepared wallet.handover.notified wallet.handover.confirmed",
    "wallet_handover",
    {
        "preparation_id": _text,
        "manifest_digest": _hash,
        "funds_paused": lambda v: v is True,
    },
    "preparation_id",
)
_add(
    "wallet",
    "wallet.legacy_stop_adopted",
    "wallet_control",
    {
        "manifest_digest": _hash,
        "successor_scope": _one("manual_tron"),
        "safety_epoch": _positive,
        "withdrawals_paused": lambda v: v is True,
        "global_restricted": lambda v: v is True,
    },
)
_add(
    "wallet",
    "wallet.manual_control.paused",
    "wallet_control",
    {"epoch": _positive, "withdrawals_paused": lambda v: v is True},
)
for _operation in ("pause", "resume"):
    _add(
        "wallet",
        "wallet.manual_control." + _operation,
        "wallet_control",
        {
            "epoch": _positive,
            "reserve_version": _nullable(_integer),
            "operation": _one(_operation),
        },
    )
_add(
    "wallet",
    "wallet.manual_deposit_case.created",
    "wallet_manual_deposit_case",
    {"receipt_id": _text, "user_id": _text},
)
_add(
    "wallet",
    "wallet.manual_deposit_case.decided",
    "wallet_manual_deposit_case",
    {"decision": _one("APPROVED", "REJECTED")},
)
_result_fields = {
    "operation_id": _text,
    "case_id": _text,
    "status": _one("EXECUTED"),
    "receipt_id": _text,
    "user_id": _text,
    "amount": _amount,
    "ledger_transaction_id": _text,
}
_result_plain = _object(_result_fields)
_result_converted = _object(dict(_result_fields, conversion=_conversion))
CATALOG[
    ("wallet", "wallet.manual_deposit_case.executed", "wallet_manual_deposit_case")
] = (lambda v: _result_plain(v) or _result_converted(v), "case_id")
_repair_fields = dict(
    _result_fields,
    intent_id=_text,
    preview_digest=_hash,
    payload_digest=_hash,
    reason_detail_digest=_hash,
    idempotency_key_digest=_hash,
    reason_code=_one(
        "CLOCK_ORDERING_REVIEW",
        "EXPIRED_INTENT_REVIEW",
        "ATTRIBUTION_CORRECTION",
        "PAYMENT_BEFORE_ORDER",
        "OTHER",
    ),
    original_intent_status=_one("OPEN", "FULFILLED", "EXPIRED", "CANCELLED"),
    original_receipt_reason=_nullable(_reason),
    payment_attestation=_boolean,
    authorization=_one("VALID_WALLET_GRANT"),
)
_repair_plain = _object(_repair_fields)
_repair_converted = _object(dict(_repair_fields, conversion=_conversion))
CATALOG[("wallet", "wallet.deposit_repair.evidence_linked", "wallet_repair")] = (
    lambda v: _repair_plain(v) or _repair_converted(v),
    "operation_id",
)
_add(
    "wallet.incident",
    """wallet.incident.opened wallet.incident.reopened wallet.incident.severity_changed
     wallet.incident.condition_cleared wallet.incident.legacy_superseded wallet.manual_incident.reviewed
     wallet.incident.ack wallet.incident.resolve wallet.incident.resolve_manual wallet.incident.escalated""",
    "wallet_incident",
    {
        "incident_id": _text,
        "subject_id": _text,
        "code": _text,
        "severity": _one("P0", "P1", "T2"),
    },
    "incident_id",
)
_add(
    "wallet.incident",
    "wallet.incident.source_timeout_reclassified",
    "wallet_incident",
    {
        "incident_id": _text,
        "subject_id": _one("global"),
        "code": _one("MANUAL_SOURCE_UNAVAILABLE"),
        "severity": _one("T2"),
    },
    "incident_id",
)

_GLOBAL_CONTRACTS = frozenset(
    {
        ("ledger", "manual_reserve.published"),
        ("ledger", "ledger.outgoing_restricted"),
        ("ledger", "ledger.manual_restriction_released"),
        ("ledger", "ledger.legacy_stop_adopted"),
        ("wallet", "wallet.funding_scan_discovered"),
        ("wallet", "wallet.legacy_stop_adopted"),
        ("wallet", "wallet.manual_control.paused"),
        ("wallet", "wallet.manual_control.pause"),
        ("wallet", "wallet.manual_control.resume"),
    }
)


def _bounded_json(value, depth=0):
    if depth > 8:
        return False
    if value is None or type(value) is bool:
        return True
    if type(value) is int:
        return -(2**63) <= value <= 2**63 - 1
    if type(value) is str:
        return len(value) <= 1024
    if type(value) is list:
        return len(value) <= 100 and all(_bounded_json(x, depth + 1) for x in value)
    if type(value) is dict:
        return len(value) <= 64 and all(
            type(k) is str and len(k) <= 100 and _bounded_json(v, depth + 1)
            for k, v in value.items()
        )
    return False


def _validate(message):
    if (
        not isinstance(message, OutboxMessage)
        or not _uuid(message.id)
        or not isinstance(message.topic, str)
        or message.topic not in INTERNAL_PUBLICATION_TOPICS
        or not isinstance(message.event_type, str)
        or len(message.event_type) > 100
        or not isinstance(message.aggregate_type, str)
        or len(message.aggregate_type) > 100
        or not _text(message.aggregate_id)
        or type(message.headers) is not dict
        or message.headers != {}
        or type(message.payload) is not dict
        or not _bounded_json(message.payload)
    ):
        raise ValueError("INVALID_INTERNAL_PUBLICATION")
    contract = CATALOG.get((message.topic, message.event_type, message.aggregate_type))
    if (
        contract is None
        or not contract[0](message.payload)
        or (contract[1] and message.payload[contract[1]] != message.aggregate_id)
        or (
            (message.topic, message.event_type) in _GLOBAL_CONTRACTS
            and message.aggregate_id != "global"
        )
    ):
        raise ValueError("INVALID_INTERNAL_PUBLICATION")


class InternalPublicationTask:
    def __init__(self, writer: AuditWriter):
        self._writer = writer

    def __call__(self, message: OutboxMessage) -> None:
        _validate(message)
        envelope = {
            "id": message.id,
            "topic": message.topic,
            "event_type": message.event_type,
            "aggregate_type": message.aggregate_type,
            "aggregate_id": message.aggregate_id,
            "payload": message.payload,
            "headers": message.headers,
        }
        try:
            encoded = json.dumps(
                envelope,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
                allow_nan=False,
            ).encode("utf-8")
        except (TypeError, ValueError, UnicodeError, RecursionError):
            raise ValueError("INVALID_INTERNAL_PUBLICATION") from None
        if len(encoded) > 65536:
            raise ValueError("INVALID_INTERNAL_PUBLICATION")
        self._writer.record_internal_publication(
            event_id=message.id,
            topic=message.topic,
            event_type=message.event_type,
            envelope_sha256=hashlib.sha256(encoded).hexdigest(),
        )
