from types import SimpleNamespace
import pytest
from Tea.exceptions import TeaException
from app.core.errors import AppError
from test_aliyun_sms_adapter import FakeClient, make_sender

@pytest.mark.parametrize("error", [ConnectionError("response mentions isv.ValidateFail"), TeaException({"code":"isv.CONFIG_ERROR", "message":"isv.ValidateFail is not available"})])
def test_unavailable_error_text_is_not_an_authoritative_wrong_code(error):
    sender=make_sender(FakeClient(check_exc=error))
    with pytest.raises(AppError) as caught:
        sender.verify("+8613800000001", "login", "123456", "c1")
    assert caught.value.code == "SMS_VERIFY_UNAVAILABLE"

def test_structured_validation_code_does_not_depend_on_exception_string():
    class Error(Exception):
        code="isv.ValidateFail"
    assert make_sender(FakeClient(check_exc=Error("redacted"))).verify("+8613800000001", "login", "123456", "c1") is False

def test_send_network_text_does_not_fake_provider_rejection():
    with pytest.raises(AppError) as caught:
        make_sender(FakeClient(send_exc=ConnectionError("gateway cached Forbidden"))).send("+8613800000001", "", "login", challenge_id="c1")
    assert caught.value.code == "SMS_PROVIDER_TIMEOUT"

def test_validate_fail_response_body_is_also_authoritative():
    assert make_sender(FakeClient(check_code="isv.ValidateFail")).verify("+8613800000001", "login", "123456", "c1") is False
