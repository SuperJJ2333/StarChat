"""Strict allowlist for immutable, nonfinancial notification diagnostics."""

TRANSIENT = frozenset({
    'HEARTBEAT_STALE', 'OBSERVATION_STALE', 'SOLID_HEAD_STALE',
    'BALANCE_UNSTABLE', 'RECONCILIATION_PENDING', 'SOURCE_READ_BUDGET_EXPIRED',
    'SOURCE_NETWORK_ERROR',
    'SOURCE_HTTP_UNAVAILABLE',
})
CONDITIONS = TRANSIENT | frozenset({
    'BALANCE_DISCREPANCY', 'CLOCK_AHEAD', 'BASELINE_NOT_REACHED',
    'SOURCE_RUN_ERROR', 'SOURCE_MALFORMED', 'SOURCE_IDENTITY_MISMATCH',
    'SOURCE_REGRESSION', 'UNKNOWN',
})
NUMBERS = frozenset({
    'observation_id', 'heartbeat_age_ms', 'observation_age_ms', 'solid_head_age_ms',
    'duration_seconds',
})


def validate_context(value):
    if not isinstance(value, dict) or set(value) - (NUMBERS | {'failed_conditions', 'initial_conditions'}):
        raise ValueError('WALLET_ALERT_CONTEXT_INVALID')
    conditions = value.get('failed_conditions')
    if (not isinstance(conditions, (list, tuple)) or len(conditions) > len(CONDITIONS)
            or any(not isinstance(item, str) or item not in CONDITIONS for item in conditions)
            or len(set(conditions)) != len(conditions)):
        raise ValueError('WALLET_ALERT_CONTEXT_INVALID')
    if any(type(value[key]) is not int or not 0 <= value[key] < 2**63
           for key in set(value) & NUMBERS):
        raise ValueError('WALLET_ALERT_CONTEXT_INVALID')
    if 'initial_conditions' in value:
        validate_context({'failed_conditions':value['initial_conditions']})
    return dict(value, failed_conditions=list(conditions))
