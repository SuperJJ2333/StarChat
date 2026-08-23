from importlib import import_module, util

import pytest


def _email_sender_module():
    assert util.find_spec("integrations.email_sender") is not None
    return import_module("integrations.email_sender")


class RecordingSmtp:
    def __init__(self, host, port, *, timeout):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.started_tls = False
        self.login_credentials = None
        self.message = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def starttls(self, *, context):
        assert context is not None
        self.started_tls = True

    def login(self, username, password):
        self.login_credentials = (username, password)

    def send_message(self, message):
        self.message = message


def test_smtp_security_modes_are_mutually_exclusive() -> None:
    module = _email_sender_module()

    with pytest.raises(ValueError, match="mutually exclusive"):
        module.SmtpConfig(
            host="smtp.example.test",
            port=587,
            from_address="noreply@example.test",
            use_starttls=True,
            use_ssl=True,
        )


def test_production_smtp_rejects_mailpit_and_plaintext(monkeypatch) -> None:
    module = _email_sender_module()
    monkeypatch.setenv("BUSINESS_ENVIRONMENT", "production")
    monkeypatch.setenv("SMTP_HOST", "mailpit")
    monkeypatch.setenv("SMTP_SECURITY", "none")

    with pytest.raises(ValueError, match="production SMTP"):
        module.SmtpConfig.from_environment()


def test_disabled_email_delivery_is_explicit_and_fail_closed(monkeypatch) -> None:
    module = _email_sender_module()
    monkeypatch.setenv("BUSINESS_ENVIRONMENT", "production")
    monkeypatch.setenv("SMTP_DELIVERY_ENABLED", "false")
    monkeypatch.setenv("SMTP_HOST", "mailpit")
    monkeypatch.setenv("SMTP_SECURITY", "none")

    sender = module.email_sender_from_environment()

    with pytest.raises(module.EmailDeliveryError, match="disabled"):
        sender.send_email_verification(
            recipient="alice@example.test",
            code="123456",
            link="https://example.test/verify-email?token=opaque",
        )


def test_email_delivery_enable_flag_rejects_ambiguous_values(monkeypatch) -> None:
    module = _email_sender_module()
    monkeypatch.setenv("SMTP_DELIVERY_ENABLED", "sometimes")

    with pytest.raises(ValueError, match="SMTP_DELIVERY_ENABLED"):
        module.email_sender_from_environment()


def test_sender_applies_timeout_auth_and_includes_code_and_link() -> None:
    module = _email_sender_module()
    transports = []

    def smtp_factory(host, port, *, timeout):
        transport = RecordingSmtp(host, port, timeout=timeout)
        transports.append(transport)
        return transport

    sender = module.SmtpEmailSender(
        module.SmtpConfig(
            host="smtp.example.test",
            port=587,
            from_address="畅聊 ChatFlow <noreply@example.test>",
            timeout_seconds=7.5,
            use_starttls=True,
            username="smtp-user",
            password="smtp-secret",
        ),
        smtp_factory=smtp_factory,
    )

    sender.send_email_verification(
        recipient="alice@example.test",
        code="123456",
        link="https://example.test/verify-email?token=opaque",
    )

    transport = transports[0]
    assert (transport.host, transport.port, transport.timeout) == (
        "smtp.example.test",
        587,
        7.5,
    )
    assert transport.started_tls is True
    assert transport.login_credentials == ("smtp-user", "smtp-secret")
    assert transport.message["To"] == "alice@example.test"
    assert transport.message["Subject"] == "畅聊 ChatFlow 邮箱验证"
    assert transport.message["From"] == "畅聊 ChatFlow <noreply@example.test>"
    body = transport.message.get_body(preferencelist=("plain",)).get_content()
    assert "欢迎注册畅聊 ChatFlow。" in body
    assert "123456" in body
    assert "https://example.test/verify-email?token=opaque" in body


def test_sender_error_never_contains_smtp_secret() -> None:
    module = _email_sender_module()

    class FailingSmtp(RecordingSmtp):
        def login(self, username, password):
            raise RuntimeError(f"login rejected for {username}:{password}")

    sender = module.SmtpEmailSender(
        module.SmtpConfig(
            host="smtp.example.test",
            port=465,
            from_address="noreply@example.test",
            use_ssl=True,
            username="smtp-user",
            password="smtp-secret",
        ),
        smtp_ssl_factory=FailingSmtp,
    )

    with pytest.raises(module.EmailDeliveryError) as exc_info:
        sender.send_email_verification(
            recipient="alice@example.test",
            code="123456",
            link="https://example.test/verify-email?token=opaque",
        )

    assert "smtp-secret" not in str(exc_info.value)
    assert "smtp-user" not in str(exc_info.value)
