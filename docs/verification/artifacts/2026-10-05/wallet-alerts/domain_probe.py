import json,os
from datetime import datetime,timedelta,timezone
from concurrent.futures import ThreadPoolExecutor
from sqlalchemy import create_engine,select,func,text
from app.core.database import create_session_factory
from app.core.outbox import OutboxEvent,OutboxMessage
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.models import WalletControl
engine=create_engine(os.environ['BUSINESS_DATABASE_URL'])
factory=create_session_factory(engine);clock=[datetime.now(timezone.utc)];service=WalletIncidentService(factory,now_factory=lambda:clock[0])
signal=dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNHEALTHY',code='MANUAL_SOURCE_UNHEALTHY',severity='P1',subject_id='global')
context=dict(failed_conditions=['BALANCE_UNSTABLE','RECONCILIATION_PENDING'],observation_id=1)
with factory() as session:
 control=session.get(WalletControl,'global');before=(control.withdrawals_paused,control.pause_reason)
 row=session.scalar(select(WalletIncident).where(WalletIncident.fingerprint==signal['fingerprint']))
 if row is not None and row.condition_active:raise RuntimeError('Rehearsal baseline source incident active')
 initial=session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.topic=='wallet.alert'))
def fail():
 with factory.begin() as session:return service.source_failure_in_session(session,signal,context,actor_id='fixture')
assert not fail();clock[0]+=timedelta(seconds=599);assert not fail();clock[0]+=timedelta(seconds=1)
with ThreadPoolExecutor(max_workers=6) as pool:assert all(pool.map(lambda _:fail(),range(6)))
with factory() as session:
 assert session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.topic=='wallet.alert'))==initial+1
 row=session.scalar(select(WalletIncident).where(WalletIncident.fingerprint==signal['fingerprint']))
 event=session.scalar(select(OutboxEvent).where(OutboxEvent.topic=='wallet.alert',OutboxEvent.aggregate_id==row.id).order_by(OutboxEvent.created_at.desc()))
 message=OutboxMessage(event.id,event.topic,event.event_type,event.aggregate_type,event.aggregate_id,dict(event.payload),dict(event.event_headers),0)
 assert event.event_headers['wallet_diagnostics']['duration_seconds']==600
for oid in (2,2,3):
 with factory.begin() as session:
  service.source_healthy_in_session(session,oid,actor_id='fixture');service.observe_in_session(session,[],complete=True,clear_prefix='manual-reserve:')
with factory() as session:assert session.get(WalletIncident,message.aggregate_id).condition_active
with factory.begin() as session:
 service.source_healthy_in_session(session,4,actor_id='fixture');service.observe_in_session(session,[],complete=True,clear_prefix='manual-reserve:')
with factory() as session:
 assert not session.get(WalletIncident,message.aggregate_id).condition_active
 control=session.get(WalletControl,'global');assert (control.withdrawals_paused,control.pause_reason)==before
 assert session.scalar(text('SELECT version_num FROM alembic_version'))=='0095_wallet_source_alerts'
from app.modules.wallet.alert_delivery import WalletAlertDelivery
prepared=WalletAlertDelivery(factory).prepare(message)
assert prepared.diagnostics['failed_conditions']==['BALANCE_UNSTABLE','RECONCILIATION_PENDING']
if os.environ.get('PROBE_ROLE')=='worker':
 from integrations.email_sender import SmtpConfig,SmtpEmailSender
 from tasks.wallet_alert_email import WalletAlertEmailHandler
 sender=SmtpEmailSender(SmtpConfig(host='smtp.example.test',port=587,from_address='alerts@example.test',use_starttls=True))
 sent=[];sender._send=lambda mail:sent.append(mail)
 handler=WalletAlertEmailHandler(factory,email_sender=sender,recipient='ops@example.test')
 handler(message);handler(message)
 assert len(sent)==1
 body=sent[0].get_content();assert '600 秒' in body and '不会自动暂停钱包' in body
 print(json.dumps({'role':'worker','smtp_preview':body,'passed':True},ensure_ascii=False))
else:print(json.dumps({'role':'api','passed':True,'concurrent_failures':6,'single_alert':True,'three_distinct_healthy':True,'control_preserved':True}))
