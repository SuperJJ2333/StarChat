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
            from_address="六合通 <noreply@example.test>",
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
    body = transport.message.get_body(preferencelist=("plain",)).get_content()
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
