from __future__ import annotations

from dataclasses import dataclass
from email.message import EmailMessage
import hashlib
import os
import re
import smtplib
import ssl
from typing import Protocol


class EmailDeliveryError(RuntimeError):
    """Sanitized SMTP delivery failure safe for retry logs."""


class DisabledEmailSender:
    """Fail closed while non-email worker maintenance remains available."""

    def send_email_verification(self, **_kwargs) -> None:
        raise EmailDeliveryError("email delivery is disabled")

    def send_password_reset(self, **_kwargs) -> None:
        raise EmailDeliveryError("email delivery is disabled")

    def send_wallet_alert(self, **_kwargs) -> None:
        raise EmailDeliveryError("email delivery is disabled")

    def send_wallet_handover(self, **_kwargs) -> None:
        raise EmailDeliveryError("email delivery is disabled")


class EmailSender(Protocol):
    def send_email_verification(
        self,
        *,
        recipient: str,
        code: str,
        link: str,
    ) -> None: ...

    def send_password_reset(self, *, recipient: str, link: str) -> None: ...

    def send_wallet_alert(self, *, recipient: str, event_id: str, code: str, severity: str) -> None: ...

    def send_wallet_handover(self, *, recipient: str, event_id: str, manifest_digest: str, incident_count: int, alert_count: int) -> None: ...


def validate_wallet_alert_recipient(recipient):
    """A configured single ASCII mailbox; no display names, lists or headers."""
    if (not isinstance(recipient,str) or len(recipient)>254
            or re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}",recipient) is None):
        raise ValueError('single wallet alert mailbox required')
    local,domain=recipient.rsplit('@',1)
    if len(local)>64 or local.startswith('.') or local.endswith('.') or '..' in recipient or any(
            len(label)>63 or label.startswith('-') or label.endswith('-') for label in domain.split('.')):
        raise ValueError('single wallet alert mailbox required')


@dataclass(frozen=True)
class SmtpConfig:
    host: str
    port: int
    from_address: str
    timeout_seconds: float = 10.0
    use_starttls: bool = False
    use_ssl: bool = False
    username: str | None = None
    password: str | None = None

    def __post_init__(self) -> None:
        if self.use_starttls and self.use_ssl:
            raise ValueError("SMTP STARTTLS and SSL are mutually exclusive")
        if not self.host.strip():
            raise ValueError("SMTP host is required")
        if not 1 <= self.port <= 65535:
            raise ValueError("SMTP port must be between 1 and 65535")
        if self.timeout_seconds <= 0:
            raise ValueError("SMTP timeout must be positive")
        if bool(self.username) != bool(self.password):
            raise ValueError("SMTP username and password must be configured together")

    @classmethod
    def from_environment(cls) -> "SmtpConfig":
        security = os.getenv("SMTP_SECURITY", "none").strip().casefold()
        if security not in {"none", "starttls", "ssl"}:
            raise ValueError("SMTP_SECURITY must be none, starttls, or ssl")
        host = os.getenv("SMTP_HOST", "mailpit")
        if os.getenv("BUSINESS_ENVIRONMENT", "development") == "production" and (
            host.strip().casefold() in {"mailpit", "localhost", "127.0.0.1"}
            or security == "none"
        ):
            raise ValueError("production SMTP requires a remote host and TLS")
        return cls(
            host=host,
            port=int(os.getenv("SMTP_PORT", "1025")),
            from_address=os.getenv("SMTP_FROM", "畅聊 ChatFlow <noreply@localhost>"),
            timeout_seconds=float(os.getenv("SMTP_TIMEOUT_SECONDS", "10")),
            use_starttls=security == "starttls",
            use_ssl=security == "ssl",
            username=os.getenv("SMTP_USERNAME") or None,
            password=os.getenv("SMTP_PASSWORD") or None,
        )


def email_sender_from_environment():
    raw_enabled = os.getenv("SMTP_DELIVERY_ENABLED", "true").strip().casefold()
    if raw_enabled not in {"true", "false"}:
        raise ValueError("SMTP_DELIVERY_ENABLED must be true or false")
    if raw_enabled == "false":
        return DisabledEmailSender()
    return SmtpEmailSender(SmtpConfig.from_environment())


class SmtpEmailSender:
    def __init__(
        self,
        config: SmtpConfig,
        *,
        smtp_factory=smtplib.SMTP,
        smtp_ssl_factory=smtplib.SMTP_SSL,
    ) -> None:
        self._config = config
        self._smtp_factory = smtp_factory
        self._smtp_ssl_factory = smtp_ssl_factory

    def send_email_verification(
        self,
        *,
        recipient: str,
        code: str,
        link: str,
    ) -> None:
        message = EmailMessage()
        message["Subject"] = "畅聊 ChatFlow 邮箱验证"
        message["From"] = self._config.from_address
        message["To"] = recipient
        message.set_content(
            "欢迎注册畅聊 ChatFlow。\n\n"
            f"验证码：{code}\n"
            "验证码将在 10 分钟后失效。\n\n"
            f"也可以点击验证链接：{link}\n"
        )
        self._send(message)

    def send_password_reset(self, *, recipient: str, link: str) -> None:
        message = EmailMessage()
        message["Subject"] = "畅聊 ChatFlow 密码重置"
        message["From"] = self._config.from_address
        message["To"] = recipient
        message.set_content(
            "我们收到了畅聊 ChatFlow 密码重置请求。\n\n"
            "链接将在 1 小时后失效。\n\n"
            f"点击重置密码：{link}\n"
        )
        self._send(message)

    def send_wallet_alert(self, *, recipient: str, event_id: str, code: str, severity: str) -> None:
        try:
            validate_wallet_alert_recipient(recipient)
            if (not self._config.use_starttls and not self._config.use_ssl
                    or not isinstance(event_id,str) or re.fullmatch('[A-Za-z0-9-]{1,36}',event_id) is None
                    or not isinstance(code,str) or re.fullmatch('[A-Z][A-Z0-9_]{0,99}',code) is None
                    or severity not in ('P0','P1')):
                raise ValueError('invalid wallet alert')
            message=EmailMessage()
            message['Subject']='畅聊 ChatFlow 钱包告警'
            message['From']=self._config.from_address
            message['To']=recipient
            digest=hashlib.sha256(('wallet-alert:'+event_id).encode('ascii')).hexdigest()
            message['Message-ID']=f'<wallet-alert-{digest}@chatflow.invalid>'
            message.set_content(f'事件 ID：{event_id}\n事件码：{code}\n等级：{severity}\n\n请登录管理后台查看并处理。\n')
            self._send(message)
        except Exception:
            raise EmailDeliveryError('SMTP wallet alert delivery failed') from None

    def send_wallet_handover(self, *, recipient: str, event_id: str, manifest_digest: str, incident_count: int, alert_count: int) -> None:
        try:
            validate_wallet_alert_recipient(recipient)
            if (not self._config.use_starttls and not self._config.use_ssl
                    or re.fullmatch('[A-Za-z0-9-]{1,36}', event_id) is None
                    or re.fullmatch('[a-f0-9]{64}', manifest_digest) is None
                    or type(incident_count) is not int or incident_count != 3
                    or type(alert_count) is not int or not 1 <= alert_count <= 10000):
                raise ValueError('invalid handover notice')
            message = EmailMessage()
            message['Subject'] = '畅聊 ChatFlow 旧钱包监控交接清单'
            message['From'], message['To'] = self._config.from_address, recipient
            message['Message-ID'] = '<wallet-handover-'+hashlib.sha256(event_id.encode()).hexdigest()+'@chatflow.invalid>'
            message.set_content(f'交接清单摘要：{manifest_digest}\n旧监控事件：{incident_count} 项\n历史通知：{alert_count} 条\n\n'
                '本通知汇总上述历史告警；原记录保留，不标记为已投递。\n'
                '资金继续暂停。请登录管理后台核对清单，确认没有未登记或未核清付款后，以动态验证码确认交接。\n')
            self._send(message)
        except Exception:
            raise EmailDeliveryError('SMTP wallet handover delivery failed') from None

    def _send(self, message: EmailMessage) -> None:
        factory = self._smtp_ssl_factory if self._config.use_ssl else self._smtp_factory
        try:
            tls_options = {'context': ssl.create_default_context()} if self._config.use_ssl else {}
            with factory(
                self._config.host,
                self._config.port,
                timeout=self._config.timeout_seconds,
                **tls_options,
            ) as client:
                if self._config.use_starttls:
                    client.starttls(context=ssl.create_default_context())
                if self._config.username and self._config.password:
                    client.login(self._config.username, self._config.password)
                refused = client.send_message(message)
                if refused:
                    raise EmailDeliveryError('SMTP recipient refused')
        except Exception:
            raise EmailDeliveryError("SMTP delivery failed") from None
