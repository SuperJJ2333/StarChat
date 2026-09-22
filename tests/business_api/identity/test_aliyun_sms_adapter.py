"""ADR-0075 实施补充：阿里云验证码短信适配器（dypnsapi）。

- SendSmsVerifyCode：`##code##` 占位符 + min 有效分钟；供应商生成验证码；
- CheckSmsVerifyCode：权威校验；False=不匹配（本地计尝试）；
  供应商不可达=异常（不计尝试、不消费）；
- 凭据/完整号码绝不进日志与错误信息；未配置/缺 SDK 一律 fail-closed。
"""
from datetime import datetime, timedelta, timezone

from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker

import app.modules.identity.models  # noqa: F401
from app.core.database import Base
from app.core.errors import AppError
from app.modules.identity.models import OtpChallenge
from app.modules.identity.phone import PhoneOtpService
from Tea.exceptions import TeaException  # noqa: F401
from app.modules.identity.sms_aliyun import AliyunDypnsSmsSender
import app.modules.identity.sms_aliyun as sms_aliyun_module


class FakeBody:
    def __init__(self, code, verdict="PASS", out_id="challenge-1"):
        self.code = code
        self.model = SimpleNamespace(verify_result=verdict, out_id=out_id)


class FakeResponse:
    def __init__(self, code):
        self.body = FakeBody(code)


class FakeClient:
    """替身：记录请求参数（模拟 SDK 客户端对象形状）。"""

    def __init__(self, send_code="OK", check_code="OK", send_exc=None, check_exc=None, verdict="PASS"):
        self.send_requests: list[dict] = []
        self.check_requests: list[dict] = []
        self.send_code, self.check_code = send_code, check_code
        self.send_exc, self.check_exc = send_exc, check_exc
        self.verdict = verdict

    def send_sms_verify_code(self, request):
        self.send_requests.append(dict(
            sign_name=request.sign_name, template_code=request.template_code,
            phone_number=request.phone_number, template_param=request.template_param))
        if self.send_exc:
            raise self.send_exc
        return FakeResponse(self.send_code)

    def check_sms_verify_code(self, request):
        self.check_requests.append(dict(
            phone_number=request.phone_number, verify_code=request.verify_code))
        if self.check_exc:
            raise self.check_exc
        response = FakeResponse(self.check_code)
        response.body.model.verify_result = self.verdict
        return response


def request_factory(class_name, kwargs):
    class Namespace:
        pass
    obj = Namespace()
    for key, value in kwargs.items():
        setattr(obj, key, value)
    return obj


def make_sender(client, **kw):
    return AliyunDypnsSmsSender(
        access_key_id="LTAI-test-id", access_key_secret="test-secret",
        sign_name="恒创联众", template_code="100001",
        region="ap-southeast-1", code_valid_minutes=5,
        client_factory=lambda: client, request_factory=request_factory, **kw)


def test_send_sends_provider_generated_template_with_placeholder():
    client = FakeClient()
    sender = make_sender(client)
    sender.send("+8613800000001", "ignored-local-code", "login", challenge_id="challenge-1")
    assert len(client.send_requests) == 1
    sent = client.send_requests[0]
    assert sent["phone_number"] == "13800000001"  # 大陆 11 位裸号
    assert sent["sign_name"] == "恒创联众" and sent["template_code"] == "100001"
    assert '"##code##"' in sent["template_param"] and '"min":"5"' in sent["template_param"]


def test_send_provider_failure_maps_to_stable_error_without_credentials():
    client = FakeClient(send_code="FAIL")
    sender = make_sender(client)
    with pytest.raises(AppError) as excinfo:
        sender.send("+8613800000001", "x", "login", challenge_id="challenge-1")
    assert excinfo.value.code == "SMS_SEND_FAILED"
    assert "LTAI" not in excinfo.value.message and "test-secret" not in excinfo.value.message


def test_send_provider_timeout_fails_closed():
    client = FakeClient(send_exc=TimeoutError("upstream"))
    sender = make_sender(client)
    with pytest.raises(AppError) as excinfo:
        sender.send("+8613800000001", "x", "login", challenge_id="challenge-1")
    assert excinfo.value.code == "SMS_PROVIDER_TIMEOUT"


def test_check_verify_maps_ok_false_and_unavailable():
    sender = make_sender(FakeClient(check_code="OK"))
    assert sender.verify("+8613800000001", "login", "123456", "challenge-1") is True
    sender = make_sender(FakeClient(verdict="FAIL"))
    assert sender.verify("+8613800000001", "login", "000000", "challenge-1") is False
    sender = make_sender(FakeClient(check_exc=TimeoutError("boom")))
    with pytest.raises(AppError) as excinfo:
        sender.verify("+8613800000001", "login", "123456", "challenge-1")
    assert excinfo.value.code == "SMS_VERIFY_UNAVAILABLE"
    sender = make_sender(FakeClient(check_code=None))
    with pytest.raises(AppError) as excinfo:
        sender.verify("+8613800000001", "login", "123456", "challenge-1")
    assert excinfo.value.code == "SMS_VERIFY_UNAVAILABLE"


def test_default_client_factory_fails_closed_without_sdk():
    """SDK 未安装的环境：生产装配明确失败，绝不伪成功；已安装则可构建。"""
    sender = AliyunDypnsSmsSender(
        access_key_id="LTAI-x", access_key_secret="s", sign_name="恒创联众",
        template_code="100001", region="ap-southeast-1")
    try:
        client = sender._get_client()
    except AppError as error:
        assert error.code == "SMS_PROVIDER_UNAVAILABLE"
        return
    assert client is not None  # SDK 已安装的环境允许构建（本套件不做真实调用）


def test_describe_has_no_credentials():
    sender = make_sender(FakeClient())
    text = str(sender.describe())
    assert "LTAI" not in text and "test-secret" not in text and "13800000001" not in text


# ---------------------------------------------------------- 供应商校验路径

@pytest.fixture()
def otp_db(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'otp.db'}",
        connect_args={"check_same_thread": False, "timeout": 15})

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, _record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    yield sessionmaker(bind=engine, expire_on_commit=False)
    engine.dispose()


class Clock:
    def __init__(self):
        self._now = datetime(2026, 9, 21, 12, 0, tzinfo=timezone.utc)

    def __call__(self):
        return self._now

    def advance(self, **kw):
        self._now = self._now + timedelta(**kw)


def make_otp(factory, sender, verifier=None, clock=None):
    return PhoneOtpService(factory, sender=sender, secret="test-otp-secret",
        now=clock or Clock(), code_verifier=verifier)


def test_provider_mode_issue_delivers_via_provider_and_verifies_by_provider(otp_db):
    client = FakeClient()
    sender = make_sender(client)
    decisions = {"13800000001:123456": True}
    otp = make_otp(otp_db, sender, verifier=lambda phone, purpose, code, challenge_id: decisions.get(
        phone[3:] + ":" + code, False))
    otp.issue(purpose="login", phone="+8613800000001", user_id="u1")
    assert len(client.send_requests) == 1  # 供应商下发
    assert otp.verify_code(purpose="login", target="+8613800000001", code="123456",
        user_id="u1") is True
    with pytest.raises(AppError):  # 单次消费
        otp.verify_code(purpose="login", target="+8613800000001", code="123456", user_id="u1")


def test_provider_mode_wrong_code_consumes_attempts_without_local_hash(otp_db):
    client = FakeClient()
    otp = make_otp(otp_db, make_sender(client),
        verifier=lambda phone, purpose, code, challenge_id: False)
    otp.issue(purpose="login", phone="+8613800000001", user_id="u1")
    for _ in range(5):
        with pytest.raises(AppError):
            otp.verify_code(purpose="login", target="+8613800000001", code="999999",
                user_id="u1")
    with otp_db() as session:
        row = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == "login"))
        assert row.attempts_left == 0 and row.consumed_at is None
    with pytest.raises(AppError):
        otp.verify_code(purpose="login", target="+8613800000001", code="123456", user_id="u1")


def test_provider_unavailable_does_not_consume_attempt_or_challenge(otp_db):
    client = FakeClient()
    sender = make_sender(client)

    def flaky(phone, purpose, code, challenge_id):
        raise AppError(code="SMS_VERIFY_UNAVAILABLE", message="暂不可用", status_code=503)

    otp = make_otp(otp_db, sender, verifier=flaky)
    otp.issue(purpose="login", phone="+8613800000001", user_id="u1")
    with pytest.raises(AppError) as excinfo:
        otp.verify_code(purpose="login", target="+8613800000001", code="123456", user_id="u1")
    assert excinfo.value.code == "SMS_VERIFY_UNAVAILABLE"
    with otp_db() as session:
        row = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == "login"))
        assert row.attempts_left == 5 and row.consumed_at is None
    # 供应商恢复后同一挑战仍可用
    otp.code_verifier = lambda phone, purpose, code, challenge_id: code == "123456"
    assert otp.verify_code(purpose="login", target="+8613800000001", code="123456",
        user_id="u1") is True


# ---------------------------------------------------------- 配置校验

def test_settings_aliyun_provider_requires_full_configuration():
    from pydantic import ValidationError

    from app.core.config import Settings

    with pytest.raises(ValidationError):
        Settings(_env_file=None, environment="test", sms_provider="aliyun_dypns")
    Settings(_env_file=None, environment="test", sms_provider="aliyun_dypns",
        sms_aliyun_access_key_id="LTAI-x", sms_aliyun_access_key_secret="s",
        sms_aliyun_sign_name="恒创联众", sms_aliyun_template_code="100001",
        sms_aliyun_region="ap-southeast-1", sms_aliyun_code_valid_minutes=5)


def test_settings_production_phone_auth_requires_aliyun_and_secret():
    from pydantic import ValidationError

    from app.core.config import Settings

    base = dict(_env_file=None, environment="production", phone_auth_enabled=True,
        jwt_secret="x" * 32, email_verification_secret="x" * 32,
        password_reset_secret="x" * 32, totp_issuer="t", synapse_admin_access_token="x",
        matrix_provision_secret="x", avatar_url_signing_secret="x",
        referral_code_secret="x", matrix_public_homeserver_url="https://m",
        avatar_public_base_url="https://a")
    with pytest.raises(ValidationError):
        Settings(**base, sms_provider="disabled")
    Settings(**base, sms_provider="aliyun_dypns", otp_hash_secret="otp-secret",
        sms_aliyun_access_key_id="LTAI-x", sms_aliyun_access_key_secret="s",
        sms_aliyun_sign_name="恒创联众", sms_aliyun_template_code="100001")


def test_settings_rejects_out_of_range_code_minutes():
    from pydantic import ValidationError

    from app.core.config import Settings

    with pytest.raises(ValidationError):
        Settings(_env_file=None, environment="test", sms_provider="aliyun_dypns",
            sms_aliyun_access_key_id="LTAI-x", sms_aliyun_access_key_secret="s",
            sms_aliyun_sign_name="恒创联众", sms_aliyun_template_code="100001",
            sms_aliyun_code_valid_minutes=11)


class RejectionError(Exception):
    """模拟阿里云 OpenAPI 的业务拒绝异常（ClientException 形状）。"""


def test_provider_403_rejection_is_classified_not_timeout(db=None):
    """RAM/权限类 403：SMS_SEND_REJECTED，而非网络超时——运维信号可区分。"""
    client = FakeClient(send_exc=TeaException({'code': 'Forbidden.NoPermission', 'message': 'access denied', 'data': {'statusCode': 403}}))
    sender = make_sender(client)
    with pytest.raises(AppError) as excinfo:
        sender.send("+8613800000001", "x", "login", challenge_id="c1")
    assert excinfo.value.code == "SMS_SEND_REJECTED"
    assert "LTAI" not in excinfo.value.message and "test-secret" not in excinfo.value.message


def test_network_failure_still_times_out_not_rejected(db=None):
    client = FakeClient(send_exc=ConnectionError("ssl eof"))
    RejectionError  # 保留引用
    sender = make_sender(client)
    with pytest.raises(AppError) as excinfo:
        sender.send("+8613800000001", "x", "login", challenge_id="c1")
    assert excinfo.value.code == "SMS_PROVIDER_TIMEOUT"


def test_validate_fail_business_error_is_authoritative_mismatch(db=None):
    """真实契约：阿里云对错码抛 isv.ValidateFail(400) 而非 200+FAIL——
    必须按“权威不匹配”处理并计入尝试，不得当作不可用。"""
    client = FakeClient(check_exc=TeaException({'code': 'isv.ValidateFail', 'message': '验证失败', 'data': {'statusCode': 400}}))
    sender = make_sender(client)
    assert sender.verify("+8613800000001", "login", "123456", "c1") is False


def test_other_isv_config_errors_stay_unavailable(db=None):
    """配置类 isv.* 错误（签名/模板缺失）不消耗用户尝试。"""
    client = FakeClient(check_exc=TeaException({'code': 'isv.SIGNATURE_NOT_FOUND', 'message': 'configuration error', 'data': {'statusCode': 400}}))
    sender = make_sender(client)
    with pytest.raises(AppError) as excinfo:
        sender.verify("+8613800000001", "login", "123456", "c1")
    assert excinfo.value.code == "SMS_VERIFY_UNAVAILABLE"
