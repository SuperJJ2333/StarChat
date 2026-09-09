"""SMTP alert handler: at-least-once delivery, never hold DB locks over SMTP."""
from app.modules.wallet.alert_delivery import WalletAlertDelivery
from integrations.email_sender import validate_wallet_alert_recipient
from app.core.outbox_handover import OutboxHandover, SUMMARY_EVENT
from app.integrations.tron import diagnostics as diag


class WalletAlertEmailHandler:
    def __init__(self,factory,*,email_sender,recipient):
        validate_wallet_alert_recipient(recipient)
        self.delivery=WalletAlertDelivery(factory)
        self.handover=OutboxHandover(factory)
        self.email_sender,self.recipient=email_sender,recipient

    @diag.traced('wallet_alert')
    def __call__(self,event):
        try:
            if event.event_type == SUMMARY_EVENT:
                summary = self.handover.prepare_delivery(event)
                if summary is None:
                    return
                self.email_sender.send_wallet_handover(recipient=self.recipient, event_id=summary['event_id'],
                    manifest_digest=summary['manifest_digest'], incident_count=summary['incident_count'], alert_count=summary['alert_count'])
                self.handover.record_smtp_delivery(event)
                diag.emit('INFO', 'alert_delivery_recorded', component='wallet_alert', event_id=event.id)
                return
            envelope=self.delivery.prepare(event)
            if envelope is None: return
            self.email_sender.send_wallet_alert(recipient=self.recipient,event_id=envelope.event_id,
                code=envelope.code,severity=envelope.severity)
            # If this commit fails after SMTP accepted the message, retry may
            # send again. Stable Message-ID is not an exactly-once guarantee.
            self.delivery.record_smtp_delivery(event)
            diag.emit('INFO', 'alert_delivery_recorded', component='wallet_alert', event_id=event.id)
        except Exception as exc:
            diag.emit('ERROR', 'alert_delivery_failed', component='wallet_alert', event_id=event.id,
                      reason_code='WALLET_ALERT_EMAIL_FAILED', **diag.exception_info(exc))
            raise RuntimeError('WALLET_ALERT_EMAIL_FAILED') from None
