from dataclasses import replace
from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent, OutboxMessage
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.incident_models import WalletAlertReceipt, WalletIncident
from app.modules.wallet import funding_models, binding_models  # noqa: F401
from integrations.email_sender import DisabledEmailSender, EmailDeliveryError, SmtpConfig, SmtpEmailSender
from test_email_sender import RecordingSmtp


@pytest.fixture
def alert():
    from tasks.wallet_alert_email import WalletAlertEmailHandler
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    WalletIncidentService(factory).observe([dict(fingerprint='FIXTURE:global',code='FIXTURE',severity='P0',subject_id='sensitive-subject')])
    with factory() as s:
        row = s.scalar(select(OutboxEvent).where(OutboxEvent.topic=='wallet.alert'))
        event = OutboxMessage(row.id,row.topic,row.event_type,row.aggregate_type,row.aggregate_id,dict(row.payload),{},0)
    class Sender:
        calls = []
        failure = False
        def send_wallet_alert(self,**kwargs):
            self.calls.append(kwargs)
            if self.failure: raise RuntimeError('smtp-secret-and-address')
    sender = Sender()
    handler = WalletAlertEmailHandler(factory,email_sender=sender,recipient='ops@example.test')
    yield handler,sender,factory,event,engine
    engine.dispose()


def test_delivery_records_smtp_only_after_send_and_retry_skips(alert):
    handler,sender,factory,event,_ = alert
    original = sender.send_wallet_alert
    def send(**kwargs):
        with factory() as s: assert s.get(WalletAlertReceipt,event.id) is None
        original(**kwargs)
    sender.send_wallet_alert = send
    handler(event); handler(event)
    assert len(sender.calls)==1
    assert set(sender.calls[0]) == {'recipient','event_id','code','severity'}
    with factory() as s:
        receipt = s.get(WalletAlertReceipt,event.id)
        assert receipt.transport=='SMTP' and receipt.incident_id==event.aggregate_id
        assert 'ops@example.test' not in str(receipt.payload)


def test_smtp_failure_sanitized_and_no_receipt(alert):
    handler,sender,factory,event,_ = alert
    sender.failure=True
    with pytest.raises(RuntimeError) as error: handler(event)
    assert str(error.value)=='WALLET_ALERT_EMAIL_FAILED'
    assert error.value.__cause__ is None
    with factory() as s: assert s.get(WalletAlertReceipt,event.id) is None


@pytest.mark.parametrize('fault',['payload','unknown_event','topic','incident','aggregate','persisted_payload'])
def test_persisted_event_and_incident_validated(alert,fault):
    handler,sender,factory,event,_ = alert
    if fault=='payload': event=replace(event,payload=event.payload|{'severity':'P1'})
    elif fault=='unknown_event': event=replace(event,id='missing')
    elif fault=='topic': event=replace(event,topic='wallet.incident')
    elif fault=='aggregate': event=replace(event,aggregate_id='missing')
    else:
        with factory.begin() as s:
            if fault=='incident': s.get(WalletIncident,event.aggregate_id).code='OTHER'
            else: s.get(OutboxEvent,event.id).payload=event.payload|{'subject_id':'other'}
    with pytest.raises(RuntimeError): handler(event)
    assert sender.calls==[]


@pytest.mark.parametrize('recipient',['','a@example.test,b@example.test','Name <a@example.test>',
    'a@example.test\r\nBcc: b@example.test','a@example.test; b@example.test','a@example.test '])
def test_only_single_mailbox_allowed(alert,recipient):
    from tasks.wallet_alert_email import WalletAlertEmailHandler
    with pytest.raises(ValueError): WalletAlertEmailHandler(alert[2],email_sender=alert[1],recipient=recipient)


def test_existing_receipt_conflict_not_accepted(alert):
    handler,sender,factory,event,_ = alert
    with factory.begin() as s:
        s.add(WalletAlertReceipt(event_id=event.id,incident_id=event.aggregate_id,transport='SANDBOX',
            payload=event.payload,created_at=datetime.now(timezone.utc)))
    with pytest.raises(RuntimeError): handler(event)
    assert sender.calls==[]


def test_smtp_has_no_open_database_transaction(alert):
    handler,sender,factory,event,engine = alert
    from sqlalchemy import event as sa_event
    active = [0]
    sa_event.listen(engine,'begin',lambda conn: active.__setitem__(0,active[0]+1))
    sa_event.listen(engine,'rollback',lambda conn: active.__setitem__(0,active[0]-1))
    sa_event.listen(engine,'commit',lambda conn: active.__setitem__(0,active[0]-1))
    def send(**kwargs): assert active[0]==0
    sender.send_wallet_alert=send
    handler(event)


def test_db_failure_after_send_can_retry_at_least_once(alert,monkeypatch):
    from app.modules.wallet.alert_delivery import WalletAlertDelivery
    handler,sender,factory,event,_ = alert
    original=WalletAlertDelivery.record_smtp_delivery
    def failure(*args,**kwargs): raise RuntimeError('database-detail')
    monkeypatch.setattr(WalletAlertDelivery,'record_smtp_delivery',failure)
    with pytest.raises(RuntimeError,match='WALLET_ALERT_EMAIL_FAILED'): handler(event)
    with factory() as s: assert s.get(WalletAlertReceipt,event.id) is None
    monkeypatch.setattr(WalletAlertDelivery,'record_smtp_delivery',original)
    handler(event)
    assert len(sender.calls)==2


def test_sender_minimal_content_stable_message_id_tls():
    transports=[]
    def factory(host,port,*,timeout):
        smtp=RecordingSmtp(host,port,timeout=timeout); transports.append(smtp); return smtp
    sender=SmtpEmailSender(SmtpConfig(host='smtp.example.test',port=587,from_address='noreply@example.test',use_starttls=True),smtp_factory=factory)
    for _ in range(2): sender.send_wallet_alert(recipient='ops@example.test',event_id='event-1',code='FIXTURE',severity='P0')
    first,second=[smtp.message for smtp in transports]
    assert first['Message-ID']==second['Message-ID']
    assert 'event-1' in first.get_content() and 'FIXTURE' in first.get_content() and 'P0' in first.get_content()
    assert all(smtp.started_tls for smtp in transports)
    with pytest.raises(EmailDeliveryError): DisabledEmailSender().send_wallet_alert(recipient='ops@example.test',event_id='event-1',code='FIXTURE',severity='P0')


def test_alert_sender_rejects_plaintext_transport():
    sender=SmtpEmailSender(SmtpConfig(host='smtp.example.test',port=25,from_address='noreply@example.test',use_starttls=False))
    with pytest.raises(EmailDeliveryError): sender.send_wallet_alert(recipient='ops@example.test',event_id='event-1',code='FIXTURE',severity='P0')


def test_sent_event_retry_survives_later_incident_severity_change(alert):
    handler,sender,factory,event,_=alert
    handler(event)
    with factory.begin() as s: s.get(WalletIncident,event.aggregate_id).severity='P1'
    handler(event)
    assert len(sender.calls)==1


def test_smtp_refused_recipient_is_not_success():
    class Refused(RecordingSmtp):
        def send_message(self,message): return {'ops@example.test':(550,b'rejected')}
    sender=SmtpEmailSender(SmtpConfig(host='smtp.example.test',port=587,from_address='noreply@example.test',use_starttls=True),smtp_factory=Refused)
    with pytest.raises(EmailDeliveryError): sender.send_wallet_alert(recipient='ops@example.test',event_id='event-1',code='FIXTURE',severity='P0')


def test_event_change_during_smtp_never_records_false_receipt(alert):
    handler,sender,factory,event,_=alert
    def send(**kwargs):
        with factory.begin() as s: s.get(OutboxEvent,event.id).payload=event.payload|{'subject_id':'changed'}
    sender.send_wallet_alert=send
    with pytest.raises(RuntimeError): handler(event)
    with factory() as s: assert s.get(WalletAlertReceipt,event.id) is None


def test_ssl_wallet_alert_uses_certificate_verification():
    import ssl
    captured=[]
    def factory(host,port,*,timeout,context=None):
        captured.append(context)
        return RecordingSmtp(host,port,timeout=timeout)
    sender=SmtpEmailSender(SmtpConfig(host='smtp.example.test',port=465,from_address='noreply@example.test',use_starttls=False,use_ssl=True),smtp_ssl_factory=factory)
    sender.send_wallet_alert(recipient='ops@example.test',event_id='event-1',code='FIXTURE',severity='P0')
    assert captured[0] is not None
    assert captured[0].check_hostname and captured[0].verify_mode==ssl.CERT_REQUIRED


@pytest.mark.parametrize('when',['before_delivery','during_smtp'])
def test_queued_historical_severity_survives_legitimate_change(alert,when):
    handler,sender,factory,event,_=alert
    def change():
        WalletIncidentService(factory).observe([dict(fingerprint='FIXTURE:global',code='FIXTURE',
            severity='P1',subject_id='sensitive-subject')])
    original=sender.send_wallet_alert
    if when=='before_delivery': change()
    else:
        def send(**kwargs):
            original(**kwargs)
            change()
        sender.send_wallet_alert=send
    handler(event)
    assert sender.calls[0]['severity']=='P0'
    with factory() as s:
        assert s.get(WalletIncident,event.aggregate_id).severity=='P1'
        assert s.get(WalletAlertReceipt,event.id).payload['severity']=='P0'
        assert s.get(OutboxEvent,event.id).payload['severity']=='P0'
