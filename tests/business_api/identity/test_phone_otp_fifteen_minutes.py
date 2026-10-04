"""O1 real service boundaries with isolated RAM SQLite and no external sends."""
import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

import app.modules.identity.models
from app.core.database import Base
from app.core.errors import AppError
from app.core.config import Settings
from app.core.outbox import OutboxPublisher
from app.modules.identity.models import OtpChallenge
from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender, build_sms_transport
from app.modules.identity.sms_aliyun import AliyunDypnsSmsSender

NOW=datetime(2026,10,5,tzinfo=timezone.utc)

@pytest.fixture
def env():
    engine=create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory=sessionmaker(bind=engine,expire_on_commit=False)
    clock=[NOW]; sender=RecordingSmsSender()
    otp=PhoneOtpService(factory,sender=sender,secret='synthetic',now=lambda:clock[0])
    yield factory,otp,sender,clock
    engine.dispose()

@pytest.mark.parametrize('purpose',sorted(PhoneOtpService.SMS_PURPOSES))
@pytest.mark.parametrize('seconds,valid',[(899,True),(900,False)])
def test_every_sms_purpose_uses_fifteen_minute_boundary(env,purpose,seconds,valid):
    factory,otp,sender,clock=env
    otp.issue(purpose=purpose,phone='+8613800000001',user_id='synthetic-owner',registration_session='synthetic-binding')
    code=sender.messages[-1][1]
    with factory() as session:
        row=session.scalar(select(OtpChallenge))
        assert row.expires_at-row.created_at==timedelta(seconds=900)
    clock[0]=NOW+timedelta(seconds=seconds)
    kwargs=dict(purpose=purpose,target='+8613800000001',code=code,user_id='synthetic-owner',registration_session='synthetic-binding')
    if valid:
        assert otp.verify_code(**kwargs)
        with pytest.raises(AppError): otp.verify_code(**kwargs)
    else:
        with pytest.raises(AppError): otp.verify_code(**kwargs)

@pytest.mark.parametrize('purpose',sorted(PhoneOtpService.EMAIL_PURPOSES))
def test_phone_service_email_otp_remains_five_minutes(env,purpose):
    factory,otp,sender,clock=env
    otp.issue(purpose=purpose,phone='synthetic@example.invalid')
    code=sender.messages[-1][1]
    with factory() as session:
        row=session.scalar(select(OtpChallenge)); assert row.expires_at-row.created_at==timedelta(seconds=300)
    clock[0]=NOW+timedelta(seconds=300)
    with pytest.raises(AppError): otp.verify_code(purpose=purpose,target='synthetic@example.invalid',code=code)

def test_queued_password_phone_otp_has_same_ttl_and_no_pre_delivery_auth(env):
    factory,otp,sender,clock=env
    otp.issue_password_phone(target='+8613800000001',user_id='synthetic-owner',
                             code_deriver=lambda _: 'synthetic-code',registration_session='synthetic-binding')
    with factory() as session:
        row=session.scalar(select(OtpChallenge))
        assert row.expires_at-row.created_at==timedelta(seconds=900)
        assert row.attempts_left==0
    assert not sender.messages
    with pytest.raises(AppError): otp.verify_code(purpose='password_reset_phone',target='+8613800000001',code='synthetic-code')


def test_extended_window_retains_purpose_target_user_and_session_binding(env):
    factory,otp,sender,clock=env
    otp.issue(purpose='registration',phone='+8613800000001',user_id='synthetic-owner',registration_session='synthetic-binding')
    clock[0]=NOW+timedelta(seconds=899)
    args=dict(purpose='registration',target='+8613800000001',code=sender.messages[-1][1],
              user_id='synthetic-owner',registration_session='synthetic-binding')
    for override in [dict(purpose='login'),dict(target='+8613800000002'),
                     dict(user_id='other-owner'),dict(registration_session='other-binding')]:
        with pytest.raises(AppError): otp.verify_code(**{**args,**override})
    with factory() as session:
        assert session.scalar(select(OtpChallenge)).attempts_left==5
    assert otp.verify_code(**args)

def test_provider_default_sends_seconds_and_template_fifteen():
    requests=[]
    client=SimpleNamespace(send_sms_verify_code=lambda r:(requests.append(r) or SimpleNamespace(body=SimpleNamespace(code='OK'))))
    sender=AliyunDypnsSmsSender(access_key_id='synthetic',access_key_secret='synthetic',sign_name='test',template_code='test',
                              client_factory=lambda:client,request_factory=lambda _,kw:kw)
    sender.send('+8613800000001','ignored','login',challenge_id='synthetic-challenge')
    assert requests[0]['valid_time']==900
    assert json.loads(requests[0]['template_param'])=={'code':'##code##','min':'15'}
    assert requests[0]['return_verify_code'] is False

@pytest.mark.parametrize('minutes',[1,5,10,14,16])
def test_provider_and_settings_reject_duration_mismatch(minutes):
    with pytest.raises(ValueError): Settings(_env_file=None,sms_aliyun_code_valid_minutes=minutes)
    with pytest.raises(ValueError): AliyunDypnsSmsSender(access_key_id='synthetic',access_key_secret='synthetic',sign_name='test',template_code='test',code_valid_minutes=minutes)

def test_default_settings_and_shared_api_worker_transport_fifteen(monkeypatch):
    settings=Settings(_env_file=None)
    assert settings.sms_aliyun_code_valid_minutes==15
    configured=settings.model_copy(update={'sms_provider':'aliyun_dypns','sms_aliyun_access_key_id':SimpleNamespace(get_secret_value=lambda:'synthetic'),
       'sms_aliyun_access_key_secret':SimpleNamespace(get_secret_value=lambda:'synthetic'),'sms_aliyun_sign_name':'test','sms_aliyun_template_code':'test'})
    sender,verifier=build_sms_transport(configured)
    assert sender.describe()['code_valid_minutes']==15 and verifier==sender.verify
