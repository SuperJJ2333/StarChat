import pytest
from pydantic import ValidationError

from app.api.admin_wallet_repairs import ManualDepositCaseBody, ManualDepositDecisionBody


@pytest.mark.parametrize('value', [1, 1.0, 'true'])
def test_manual_case_attestation_rejects_non_boolean_true(value):
    with pytest.raises(ValidationError):
        ManualDepositCaseBody(receipt_id='receipt-1', user_id='user-1', reason_detail='evidence', ownership_attestation=value)


@pytest.mark.parametrize('value', [1, 1.0, 'true'])
def test_manual_case_decision_confirmation_rejects_non_boolean_true(value):
    with pytest.raises(ValidationError):
        ManualDepositDecisionBody(decision='APPROVED', reason_detail='evidence', confirmed=value)


def test_manual_case_confirmations_accept_only_literal_true():
    assert ManualDepositCaseBody(receipt_id='receipt-1', user_id='user-1', reason_detail='evidence', ownership_attestation=True).ownership_attestation is True
    assert ManualDepositDecisionBody(decision='APPROVED', reason_detail='evidence', confirmed=True).confirmed is True
