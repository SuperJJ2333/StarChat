"""Executed in the existing worker; credentials never leave its environment."""
from email.message import EmailMessage
import json
import os
import re
import smtplib
import ssl
import sys

REASONS = {'REFRESH_422', 'REFRESH_5XX', 'REFRESH_FAILURE_RATE', 'PROTOCOL_PROBE_FAILED',
           'MONITOR_CHECK_FAILED', 'LOG_WINDOW_TRUNCATED', 'MONITOR_STATE_INVALID', 'DELIVERY_TEST'}


def send(event):
    from integrations.email_sender import SmtpConfig, validate_wallet_alert_recipient
    if os.environ.get('SMTP_DELIVERY_ENABLED', 'true').lower() != 'true':
        raise ValueError('Delivery disabled')
    config = SmtpConfig.from_environment()
    if not config.use_starttls and not config.use_ssl:
        raise ValueError('TLS required')
    recipient = os.environ.get('BUSINESS_WALLET_ALERT_RECIPIENT', '')
    validate_wallet_alert_recipient(recipient)
    if not re.fullmatch('[a-f0-9-]{36}', event.get('id', '')) or event.get('kind') not in ('alert', 'recovery', 'test'):
        raise ValueError('Invalid event')
    if not isinstance(event.get('reasons'), list) or set(event['reasons']) - REASONS:
        raise ValueError('Invalid reason')
    message = EmailMessage()
    message['Subject'] = '畅聊 ChatFlow 登录续期监控：' + {'alert':'异常', 'recovery':'恢复', 'test':'通道验证'}[event['kind']]
    message['From'], message['To'] = config.from_address, recipient
    message['Message-ID'] = '<refresh-watch-'+event['id']+'@chatflow.invalid>'
    message.set_content('事件ID：'+event['id']+'\n类型：'+event['kind']+'\n原因：'+','.join(event['reasons'])+
        '\n\n请在服务器查看 systemctl status starchat-refresh-watch.timer 与 /var/lib/starchat-refresh-watch/state.json。\n'
        '通知不包含用户信息或凭证；恢复通知不表示此前邮件已成功送达。\n')
    factory = smtplib.SMTP_SSL if config.use_ssl else smtplib.SMTP
    kwargs = {'context':ssl.create_default_context()} if config.use_ssl else {}
    with factory(config.host, config.port, timeout=min(config.timeout_seconds, 15), **kwargs) as client:
        if config.use_starttls:
            client.starttls(context=ssl.create_default_context())
        if config.username:
            client.login(config.username, config.password)
        if client.send_message(message):
            raise ValueError('Delivery refused')


if __name__ == '__main__':
    try:
        send(json.loads(sys.stdin.read(4096)))
        print('SMTP_ACCEPTED')
    except Exception:
        print('ALERT_DELIVERY_FAILED')
        sys.exit(1)
