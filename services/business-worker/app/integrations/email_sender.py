from __future__ import annotations

from dataclasses import dataclass
from email.message import EmailMessage
import os
import smtplib
import ssl
from typing import Protocol


class EmailDeliveryError(RuntimeError):
    """Sanitized SMTP delivery failure safe for retry logs."""


class EmailSender(Protocol):
    def send_email_verification(
        self,
        *,
        recipient: str,
        code: str,
        link: str,
    ) -> None: ...

    def send_password_reset(self, *, recipient: str, link: str) -> None: ...


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
            from_address=os.getenv("SMTP_FROM", "六合通 <noreply@localhost>"),
            timeout_seconds=float(os.getenv("SMTP_TIMEOUT_SECONDS", "10")),
            use_starttls=security == "starttls",
            use_ssl=security == "ssl",
            username=os.getenv("SMTP_USERNAME") or None,
            password=os.getenv("SMTP_PASSWORD") or None,
        )


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
        message["Subject"] = "六合通邮箱验证"
        message["From"] = self._config.from_address
        message["To"] = recipient
        message.set_content(
            "欢迎注册六合通。\n\n"
            f"验证码：{code}\n"
            "验证码将在 10 分钟后失效。\n\n"
            f"也可以点击验证链接：{link}\n"
        )
        self._send(message)

    def send_password_reset(self, *, recipient: str, link: str) -> None:
        message = EmailMessage()
        message["Subject"] = "六合通密码重置"
        message["From"] = self._config.from_address
        message["To"] = recipient
        message.set_content(
            "我们收到了六合通密码重置请求。\n\n"
            "链接将在 1 小时后失效。\n\n"
            f"点击重置密码：{link}\n"
        )
        self._send(message)

    def _send(self, message: EmailMessage) -> None:
        factory = self._smtp_ssl_factory if self._config.use_ssl else self._smtp_factory
        try:
            with factory(
                self._config.host,
                self._config.port,
                timeout=self._config.timeout_seconds,
            ) as client:
                if self._config.use_starttls:
                    client.starttls(context=ssl.create_default_context())
                if self._config.username and self._config.password:
                    client.login(self._config.username, self._config.password)
                client.send_message(message)
        except Exception:
            raise EmailDeliveryError("SMTP delivery failed") from None
