from integrations.email_sender import SmtpEmailSender, SmtpConfig
from test_email_sender import RecordingSmtp


def test_email_explains_immutable_reason_time_impact_and_action():
    sent = []
    def factory(*args, **kwargs):
        smtp = RecordingSmtp(*args, **kwargs)
        sent.append(smtp)
        return smtp
    sender = SmtpEmailSender(SmtpConfig(host='smtp.example.test', port=587,
        from_address='alerts@example.test', use_starttls=True), smtp_factory=factory)
    sender.send_wallet_alert(recipient='ops@example.test', event_id='event-1',
        code='MANUAL_SOURCE_UNHEALTHY', severity='P1', incident_id='incident-1',
        occurred_at='2026-10-04T16:00:27Z',
        diagnostics={'failed_conditions':['BALANCE_UNSTABLE', 'RECONCILIATION_PENDING'],
                     'duration_seconds':600})
    message = sent[0].message
    body = message.get_content()
    assert '[P1]' in message['Subject'] and '链上观察' in message['Subject']
    for expected in ('余额采样不稳定', '对账尚未确认', '600 秒',
                     '2026-10-05 00:00:27', 'incident-1',
                     '不会自动暂停钱包', '管理员', '处理建议'):
        assert expected in body
    assert '网络超时' not in body


def test_email_preserves_explicit_head_regression():
    sent=[]
    def factory(*args,**kwargs):
        smtp=RecordingSmtp(*args,**kwargs);sent.append(smtp);return smtp
    sender=SmtpEmailSender(SmtpConfig(host='smtp.example.test',port=587,
        from_address='alerts@example.test',use_starttls=True),smtp_factory=factory)
    sender.send_wallet_alert(recipient='ops@example.test',event_id='event-1',
        code='MANUAL_SOURCE_UNHEALTHY',severity='P1',incident_id='incident-1',
        occurred_at='2026-10-15T00:00:00Z',diagnostics={'failed_conditions':['SOLID_HEAD_REGRESSED'],
        'initial_conditions':['SOLID_HEAD_REGRESSED'],'duration_seconds':12})
    body=sent[0].message.get_content()
    assert '区块头倒退' in body and '底层起因尚未确认' not in body
    assert '不会自动暂停钱包' in body
