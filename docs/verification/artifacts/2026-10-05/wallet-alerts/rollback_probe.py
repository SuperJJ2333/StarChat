import os,json
from sqlalchemy import create_engine,select,text
from app.core.database import create_session_factory
from app.core.outbox import OutboxEvent,OutboxMessage
from app.modules.wallet.models import WalletControl
from app.modules.wallet.alert_delivery import WalletAlertDelivery
from app.modules.wallet.incident_models import WalletAlertReceipt
factory=create_session_factory(create_engine(os.environ['BUSINESS_DATABASE_URL']))
role=os.environ['PROBE_ROLE']
if role=='producer':
 from app.modules.wallet.incidents import WalletIncidentService
 service=WalletIncidentService(factory)
 signal=dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNHEALTHY',code='MANUAL_SOURCE_UNHEALTHY',severity='P1',subject_id='global')
 for cause in ('SOURCE_MALFORMED','SOURCE_IDENTITY_MISMATCH'):
  with factory.begin() as session:service.source_failure_in_session(session,signal,dict(failed_conditions=[cause]),actor_id='fixture')
else:
 with factory() as session:
  assert session.scalar(text('SELECT version_num FROM alembic_version'))=='0095_wallet_source_alerts'
  control=session.get(WalletControl,'global');before=(control.withdrawals_paused,control.pause_reason)
  row=session.scalar(select(OutboxEvent).where(OutboxEvent.topic=='wallet.alert',OutboxEvent.event_type=='wallet.incident.cause_changed').order_by(OutboxEvent.created_at.desc()))
  assert row is not None
  event=OutboxMessage(row.id,row.topic,row.event_type,row.aggregate_type,row.aggregate_id,dict(row.payload),dict(row.event_headers),0)
  receipt=session.scalar(select(WalletAlertReceipt).where(WalletAlertReceipt.event_id!=row.id).order_by(WalletAlertReceipt.created_at.desc()))
  assert receipt is not None
  old=session.get(OutboxEvent,receipt.event_id)
  replay=OutboxMessage(old.id,old.topic,old.event_type,old.aggregate_type,old.aggregate_id,dict(old.payload),dict(old.event_headers),0)
 assert WalletAlertDelivery(factory).prepare(replay) is None
 assert WalletAlertDelivery(factory).prepare(event).diagnostics['failed_conditions']==['SOURCE_IDENTITY_MISMATCH']
 if role=='worker':
  from integrations.email_sender import SmtpConfig,SmtpEmailSender
  from tasks.wallet_alert_email import WalletAlertEmailHandler
  sender=SmtpEmailSender(SmtpConfig(host='smtp.example.test',port=587,from_address='alerts@example.test',use_starttls=True));sent=[];sender._send=lambda mail:sent.append(mail)
  handler=WalletAlertEmailHandler(factory,email_sender=sender,recipient='ops@example.test');handler(event);handler(event);handler(replay)
  assert len(sent)==1
 with factory() as session:
  control=session.get(WalletControl,'global');assert (control.withdrawals_paused,control.pause_reason)==before
print(json.dumps({'role':role,'passed':True,'cause_changed_compatible':True,'receipt_replay_compatible':True}))
