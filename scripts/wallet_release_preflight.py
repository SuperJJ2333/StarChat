"""Read-only release gate for production with real-wallet funding disabled.

Run with the release's BUSINESS_* environment, locally or inside its container.
This verifies schema presence, not balances, constraints, or external readiness.
Only fixed public status codes are emitted; configuration/errors are never printed.
"""
import json
from pathlib import Path
import sys

from sqlalchemy import create_engine, inspect, text

BUSINESS_API = Path(__file__).resolve().parents[1] / 'services' / 'business-api'
if BUSINESS_API.is_dir():
    sys.path.insert(0, str(BUSINESS_API))

from app.core.config import Settings  # noqa: E402
from app.integrations.custody.factory import create_custody_provider  # noqa: E402

EXPECTED_HEAD = '0059_chat_payment_pin'
# Explicit release contract: do not derive this from the database being checked.
REQUIRED_COLUMNS = {
    'direct_room_reservations': 'id user_low_id user_high_id owner_id attempt_id created_at',
    'identity_admin_operation_credentials': 'user_id password_hash version created_at updated_at',
    'identity_admin_operation_attempts': 'user_id failed_count window_started_at locked_until',
    'identity_admin_operation_commands': 'id actor_id idempotency_key request_hash credential_version result created_at',
    'wallet_funding_scan_state': 'id source_identity cursor_rowid source_max_rowid checkpoint_ms updated_at',
    'wallet_funding_scan_items': 'txid state discovered_rowid attempts last_reason created_at updated_at',
    'wallet_funding_coverage_events': 'id source_identity source_rowid txid log_index status facts_digest proof verified_at',
    'ledger_manual_reserve_evaluations': 'id idempotency_key payload_digest source_identity observation_id cut_digest result_version evidence created_at',
    'wallet_deposit_intents': 'id user_id binding_id binding_version status expires_at',
    'wallet_deposit_receipts': 'id txid log_index status pending_obligation ledger_transaction_id',
    'wallet_manual_payout_orders': 'id status',
    'ledger_outgoing_restrictions': 'scope active epoch reason_code actor_id updated_at',
    'wallet_manual_control_states': 'id epoch owns_pause owns_safety safety_epoch updated_at',
    'wallet_manual_control_commands': 'idempotency_key payload_digest result created_at',
    'wallet_handover_preparations': 'id actor_id idempotency_key manifest_digest manifest expires_at',
    'wallet_handover_commands': 'idempotency_key payload_digest result created_at',
    'wallet_incident_handover_dispositions': 'incident_id generation handover_id manifest_digest disposition',
    'outbox_handover_notices': 'id preparation_id manifest_digest payload_digest created_at',
    'outbox_handover_members': 'event_id notice_id original_snapshot manifest_digest',
    'outbox_handover_receipts': 'notice_id payload_digest transport created_at',
    'outbox_handover_dispositions': 'event_id notice_id manifest_digest disposition',
    'wallet_address_owners': 'address user_id created_at',
    'wallet_binding_states': 'user_id version active_binding_id pending_binding_id last_rebind_at',
    'wallet_bindings': 'id user_id address version status created_at activated_at effective_from_block effective_to_block barrier_height barrier_block_id barrier_source_ids barrier_observed_at',
    'wallet_binding_challenges': 'id user_id session_digest domain network address expected_version message created_at expires_at consumed_at',
    'wallet_binding_requests': 'id user_id operation idempotency_key digest response created_at',
    'wallet_ledger_transactions': 'id asset scope idempotency_key actor_id reason_code created_at',
    'wallet_ledger_entries': 'id transaction_id account_id asset amount created_at',
    'ledger_transactions': 'id asset scope idempotency_key actor_id reason_code reversal_of_id created_at',
    'ledger_entries': 'id transaction_id account_id asset amount created_at',
    'wallet_deposits': 'id event_id user_id txid amount confirmations status created_at',
    'wallet_deposit_addresses': 'id user_id asset address created_at',
    'wallet_withdrawals': 'id user_id client_order_id address amount status finance_approver_id admin_approver_id provider_txid created_at updated_at',
    'wallet_controls': 'id withdrawals_paused pause_reason',
    'wallet_webhook_events': 'event_id event_type received_at',
    'wallet_conversions': 'id user_id idempotency_key direction requested_amount source_amount target_amount status created_at',
    'wallet_payout_intents': 'withdrawal_id digest epoch created_at',
    'wallet_withdrawal_authorizations': 'withdrawal_id request_digest',
    'wallet_safety_states': 'id restricted epoch reason',
    'ledger_redeemability_reserve': 'id eligible_usdt usdt_liability version pending_payouts outgoing_restricted observed_at',
    'wallet_daily_closes': 'id day revision previous_id digest report created_by created_at reason_code idempotency_key',
    'wallet_incidents': 'id fingerprint code severity subject_id status generation version condition_active opened_at last_seen_at cleared_at acknowledged_at resolved_at acknowledged_by resolved_by clearance_digest last_escalation_slot',
    'wallet_incident_commands': 'idempotency_key payload_digest result created_at',
    'wallet_alert_receipts': 'event_id incident_id transport payload created_at',
    'wallet_monitor_heartbeats': 'id last_attempt_at last_success_at last_error_code external_delivery_configured',
    'audit_events': 'id actor_id subject_type subject_id action result reason_code trace_id source_ip source_device_id before_data after_data created_at',
    'outbox_events': 'id topic event_type aggregate_type aggregate_id payload event_headers status attempt_count available_at locked_at locked_by last_error created_at published_at',
}


def check_release() -> str:
    try:
        settings = Settings(_env_file=None)
    except Exception:
        return 'SETTINGS_INVALID'
    if settings.environment != 'production':
        return 'ENVIRONMENT_NOT_PRODUCTION'
    if settings.wallet_conversions_enabled:
        return 'CONVERSIONS_ENABLED'
    if settings.wallet_real_funds_enabled:
        return 'REAL_FUNDS_ENABLED'
    # None inherits the legacy gate, already verified disabled above.
    # Explicit independent capabilities must also be disabled (ADR 0056).
    for field, code in (
        ('wallet_deposits_enabled', 'DEPOSITS_ENABLED'),
        ('wallet_payout_requests_enabled', 'PAYOUT_REQUESTS_ENABLED'),
        ('wallet_payout_execution_enabled', 'PAYOUT_EXECUTION_ENABLED'),
    ):
        if getattr(settings, field):
            return code
    try:
        provider, _ = create_custody_provider(settings)
    except Exception:
        return 'PROVIDER_CHECK_FAILED'
    if provider is not None:
        return 'FUNDING_PROVIDER_ENABLED'

    engine = None
    try:
        engine = create_engine(settings.database_url, echo=False, hide_parameters=True)
        with engine.connect() as connection:
            if connection.scalar(text('SELECT 1')) != 1:
                return 'DATABASE_CHECK_FAILED'
            inspector = inspect(connection)
            tables = set(inspector.get_table_names())
            if 'alembic_version' not in tables:
                return 'MIGRATION_HEAD_MISMATCH'
            heads = list(connection.execute(text('SELECT version_num FROM alembic_version')).scalars())
            if heads != [EXPECTED_HEAD]:
                return 'MIGRATION_HEAD_MISMATCH'
            for table, columns in REQUIRED_COLUMNS.items():
                if table not in tables:
                    return 'SCHEMA_INCOMPLETE'
                actual = {column['name'] for column in inspector.get_columns(table)}
                if not set(columns.split()).issubset(actual):
                    return 'SCHEMA_INCOMPLETE'
    except Exception:
        return 'DATABASE_CHECK_FAILED'
    finally:
        if engine is not None:
            engine.dispose()
    return ('RELEASE_READY_MANUAL_FUNDS_DISABLED' if settings.wallet_real_mode == 'manual_tron'
            else 'RELEASE_READY_FUNDS_DISABLED')


def main() -> int:
    try:
        code = check_release()
    except Exception:
        code = 'PREFLIGHT_FAILED'
    ready = code in {'RELEASE_READY_FUNDS_DISABLED', 'RELEASE_READY_MANUAL_FUNDS_DISABLED'}
    payload = {'code': code, 'ready': ready}
    if ready:
        payload['monitor'] = ('MANUAL_ACCEPTANCE_PENDING'
            if code == 'RELEASE_READY_MANUAL_FUNDS_DISABLED' else 'UNAVAILABLE_NO_PROVIDER')
    print(json.dumps(payload, sort_keys=True))
    return 0 if ready else 1


if __name__ == '__main__':
    raise SystemExit(main())
