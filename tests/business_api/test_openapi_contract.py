import json
from pathlib import Path

from scripts.export_openapi import build_document, render_document


ROOT = Path(__file__).parents[2]
CONTRACT_PATH = ROOT / "packages" / "api-contracts" / "openapi" / "liuhetong-v1.yaml"


def test_committed_openapi_matches_generated_document() -> None:
    committed = CONTRACT_PATH.read_text(encoding="utf-8")
    assert committed == render_document(build_document())


def test_contract_exposes_health_identity_and_support_routes() -> None:
    document = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))

    assert document["info"]["title"] == "六合通 Business API"
    assert set(document["paths"]) == {
        "/api/v1/health/live",
        "/api/v1/health/ready",
        "/api/v1/invitations/validate",
        "/api/v1/auth/register",
        "/api/v1/auth/verify-email",
        "/api/v1/auth/login",
        "/api/v1/auth/refresh",
        "/api/v1/auth/logout",
        "/api/v1/auth/password/forgot",
        "/api/v1/auth/password/reset",
        "/api/v1/devices",
        "/api/v1/devices/{device_id}",
        "/api/v1/support/identities/{user_id}",
        "/api/v1/support/tickets",
        "/api/v1/support/tickets/{ticket_id}/assign",
        "/api/v1/support/tickets/{ticket_id}/transfer",
        "/api/v1/support/tickets/{ticket_id}/close",
        "/api/v1/support/agents/{agent_id}/presence",
        "/api/v1/ledger/balances/me",
        "/api/v1/ledger/transfers",
        "/api/v1/ledger/adjustment-policies/{actor_id}",
        "/api/v1/ledger/adjustments",
        "/api/v1/ledger/adjustments/{request_id}/finance-review",
        "/api/v1/ledger/adjustments/{request_id}/admin-review",
        "/api/v1/ledger/adjustments/{request_id}/execute",
        "/api/v1/red-packets",
        "/api/v1/red-packets/{packet_id}/claims",
        "/api/v1/red-packets/{packet_id}/cancel",
        "/api/v1/wallet/balances/me",
        "/api/v1/wallet/withdrawals",
        "/api/v1/wallet/withdrawals/{withdrawal_id}/finance-approve",
        "/api/v1/wallet/withdrawals/{withdrawal_id}/admin-approve",
        "/api/v1/wallet/withdrawals/{withdrawal_id}/submit",
        "/api/v1/wallet/webhooks/custody",
    }
    assert not any(
        segment in path
        for path in document["paths"]
        for segment in ()
    )


def test_contract_contains_stable_error_schema() -> None:
    document = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    schemas = document["components"]["schemas"]

    assert schemas["ErrorEnvelope"]["required"] == ["error"]
    assert set(schemas["ErrorBody"]["required"]) == {
        "code",
        "message",
        "trace_id",
        "fields",
    }





