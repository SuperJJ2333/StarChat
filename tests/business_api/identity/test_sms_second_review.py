"""Isolated SMS provider security regressions; no external requests."""
from types import SimpleNamespace

import pytest


def test_default_client_uses_central_dypns_endpoint(monkeypatch):
    import sys
    from types import ModuleType, SimpleNamespace
    from app.modules.identity.sms_aliyun import AliyunDypnsSmsSender
    package = ModuleType('alibabacloud_dypnsapi20170525')
    client = ModuleType('alibabacloud_dypnsapi20170525.client')
    client.Client = lambda config: config
    openapi = ModuleType('alibabacloud_tea_openapi')
    openapi.models = SimpleNamespace(Config=lambda **kw: SimpleNamespace(**kw))
    monkeypatch.setitem(sys.modules, package.__name__, package)
    monkeypatch.setitem(sys.modules, client.__name__, client)
    monkeypatch.setitem(sys.modules, openapi.__name__, openapi)
    sender = AliyunDypnsSmsSender(access_key_id='test', access_key_secret='test',
        sign_name='test', template_code='test')
    config = sender._default_client_factory()
    assert config.endpoint == 'dypnsapi.aliyuncs.com'
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.models import OtpChallenge
from app.modules.identity.phone import RecordingSmsSender
from test_aliyun_sms_adapter import make_sender, FakeClient
from test_phone_auth import env, _activate


@pytest.mark.parametrize("verdict", ["FAIL", "UNKNOWN", None])
def test_provider_transport_ok_without_pass_never_authenticates(verdict):
    client = FakeClient()
    client.check_sms_verify_code = lambda request: SimpleNamespace(body=SimpleNamespace(
        code="OK", success=True, model=SimpleNamespace(verify_result=verdict)))
    sender = make_sender(client)
    try:
        accepted = sender.verify("+8613800000001", "login", "000000", "challenge-1")
    except AppError:
        accepted = False
    assert accepted is False


def test_provider_enabled_email_rebind_uses_local_email_proof(env):
    factory, registration, otp, auth, _, _, _ = env
    result = registration.register(username="emailprovider", email="provider@example.com",
        password="correct horse battery staple", invitation_code="WELCOME-1",
        idempotency_key="email-provider-reg")
    _activate(factory, result.user_id)
    auth._email_code_deriver = lambda otp_id: "124578"
    provider_calls = []
    def sms_verify(target, purpose, code, challenge_id):
        provider_calls.append((target, purpose))
        return False
    otp.code_verifier = sms_verify
    auth.request_old_channel_verification(user_id=result.user_id)
    assert auth.confirm_old_channel(user_id=result.user_id, code="124578") == {"verified": True}
    assert provider_calls == []


def test_failed_delivery_leaves_no_verifiable_new_challenge(env):
    factory, _, otp, _, _, _, _ = env
    class UnavailableSender:
        def send_challenge(self, *args):
            raise AppError(code="SMS_SEND_FAILED", message="unavailable", status_code=503)
    otp.sender = UnavailableSender()
    otp.code_verifier = lambda target, purpose, code, challenge_id: True
    with pytest.raises(AppError, match="unavailable"):
        otp.issue(purpose="login", phone="+8613800000001")
    with pytest.raises(AppError):
        otp.verify_code(purpose="login", target="+8613800000001", code="123456")


def test_provider_requests_bind_distinct_purposes_and_issuances():
    client = FakeClient()
    sent = []
    client.send_sms_verify_code = lambda request: sent.append(vars(request)) or SimpleNamespace(
        body=SimpleNamespace(code="OK"))
    sender = make_sender(client)
    sender.send("+8613800000001", "unused-1", "login", challenge_id="challenge-1")
    sender.send("+8613800000001", "unused-2", "phone_rebind_old", challenge_id="challenge-2")
    sender.send("+8613800000001", "unused-3", "login", challenge_id="challenge-3")
    assert sent[0] != sent[1], "different OTP purposes have identical provider request identity"
    assert len({request["scheme_name"] for request in sent}) == 3
    assert all(len(request["scheme_name"]) <= 20 for request in sent)
    checked = []
    def verify(request):
        checked.append(vars(request))
        return SimpleNamespace(body=SimpleNamespace(code="OK", model=SimpleNamespace(
            verify_result="PASS", out_id=request.out_id)))
    client.check_sms_verify_code = verify
    assert sender.verify("+8613800000001", "login", "123456", "challenge-1")
    assert checked[0]["scheme_name"] == sent[0]["scheme_name"]
    assert checked[0]["out_id"] == sent[0]["out_id"]


def test_provider_success_false_rejects_even_pass():
    client = FakeClient()
    client.check_sms_verify_code = lambda request: SimpleNamespace(body=SimpleNamespace(
        code="OK", success=False, model=SimpleNamespace(verify_result="PASS", out_id="current")))
    with pytest.raises(AppError):
        make_sender(client).verify("+8613800000001", "login", "123456", "current")


@pytest.mark.parametrize("out_id", ["other-challenge", None])
def test_provider_pass_cannot_verify_another_local_challenge(out_id):
    client = FakeClient()
    client.check_sms_verify_code = lambda request: SimpleNamespace(body=SimpleNamespace(
        code="OK", model=SimpleNamespace(verify_result="PASS", out_id=out_id)))
    assert make_sender(client).verify("+8613800000001", "login", "123456", "current") is False


def test_failed_deliveries_remain_counted_in_quota(env):
    factory, _, otp, _, _, _, _ = env
    class UnavailableSender:
        def send_challenge(self, *args):
            raise AppError(code="SMS_SEND_FAILED", message="unavailable", status_code=503)
    otp.sender = UnavailableSender()
    for _ in range(3):
        with pytest.raises(AppError) as error:
            otp.issue(purpose="login", phone="+8613800000001")
        assert error.value.code == "SMS_SEND_FAILED"
    with pytest.raises(AppError) as error:
        otp.issue(purpose="login", phone="+8613800000001")
    assert error.value.code == "OTP_SEND_RATE_LIMITED"
    with factory() as session:
        rows = session.scalars(select(OtpChallenge)).all()
        assert len(rows) == 3
        assert all(row.invalidated_at is not None and row.attempts_left == 0 for row in rows)


def test_late_delivery_completion_does_not_resurrect_superseded_challenge(env):
    factory, _, otp, _, _, clock, _ = env
    class ReentrantSender(RecordingSmsSender):
        def send(self, phone, code, purpose):
            super().send(phone, code, purpose)
            if len(self.messages) == 1:
                with pytest.raises(AppError):
                    otp.verify_code(purpose=purpose, target=phone, code=code)
                clock.advance(seconds=1)
                otp.issue(purpose=purpose, phone=phone)
    sender = ReentrantSender()
    otp.sender = sender
    otp.issue(purpose="login", phone="+8613800000001")
    with factory() as session:
        rows = session.scalars(select(OtpChallenge).order_by(OtpChallenge.created_at)).all()
        assert rows[0].invalidated_at is not None and rows[0].attempts_left == 0
        assert rows[1].invalidated_at is None and rows[1].attempts_left == 5
    assert otp.verify_code(purpose="login", target="+8613800000001", code=sender.messages[-1][1])
