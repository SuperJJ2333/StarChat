from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
import hashlib
import os
import re
import smtplib
import ssl
from typing import Protocol
from app.modules.wallet.alert_context import validate_context


WALLET_REASONS = {
    'BALANCE_UNSTABLE': '余额采样不稳定：同轮采样尚未获得一致的余额观察。',
    'RECONCILIATION_PENDING': '对账尚未确认：需要连续可比较的稳定快照完成对账。',
    'HEARTBEAT_STALE': '观察进程心跳过期：未及时获得新的成功运行记录。',
    'OBSERVATION_STALE': '链上观察数据过期：最新快照已超出有效时间。',
    'SOLID_HEAD_STALE': '链上确认区块过期：确认区块进度未及时更新。',
    'SOURCE_READ_BUDGET_EXPIRED': '观察库读取超时：读取未在预算内完成，锁等待或存储原因尚未确认。',
    'SOURCE_NETWORK_ERROR': '网络访问失败：请求数据源时发生已识别的连接或超时异常。',
    'SOURCE_HTTP_UNAVAILABLE': '数据源服务暂不可用：实际请求返回限流（429）或服务端错误（5xx）。',
    'SOURCE_RUN_ERROR': '数据源采样失败：观察任务未成功完成，底层起因尚未确认。',
    'BALANCE_DISCREPANCY': '链上余额与已观察收支存在对账差额，请立即核查。',
    'CLOCK_AHEAD': '观察记录时间超前：服务器或数据源时间异常。',
    'BASELINE_NOT_REACHED': '观察进度尚未达到启用基线。',
    'SOURCE_MALFORMED': '数据源格式或字段校验失败。',
    'SOURCE_IDENTITY_MISMATCH': '数据源身份与配置不匹配。',
    'SOURCE_REGRESSION': '数据源进度回退，需要核对恢复或替换操作。',
    'UNKNOWN': '当前事件未确认具体底层起因，请查看事故时间线与观察诊断。',
}
WALLET_PROBLEMS = {
    'MANUAL_SOURCE_UNHEALTHY': '链上观察暂未通过健康检查',
    'MANUAL_SOURCE_UNAVAILABLE': '链上观察数据读取失败',
    'MANUAL_SOURCE_INVALID': '链上观察证据校验失败',
    'MANUAL_MONITOR_UNAVAILABLE': '钱包监控执行失败',
    'MANUAL_PAYOUT_UNCERTAIN': '人工出款结果尚未确认',
    'MANUAL_BACKING_DEFICIT': '链上储备低于监控核对要求',
    'MANUAL_RESERVE_DEFICIT': '可核验储备不足',
    'MANUAL_COVERAGE_CONFLICT': '充值覆盖证据冲突',
    'MANUAL_UNALLOCATED_OUTFLOW': '存在尚未归属的链上转出',
    'LEDGER_INTEGRITY': '账本完整性检查异常',
    'ALERT_DELIVERY_UNHEALTHY': '告警通知通道异常',
}


class EmailDeliveryError(RuntimeError):
    """Sanitized SMTP delivery failure safe for retry logs."""


class DisabledEmailSender:
    """Fail closed while non-email worker maintenance remains available."""

    def send_email_verification(self, **_kwargs) -> None:
        raise EmailDeliveryError("email delivery is disabled")

    def send_email_otp(self, **_kwargs) -> None:
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

    def send_email_otp(self, *, recipient: str, code: str, purpose: str) -> None: ...

    def send_password_reset(self, *, recipient: str, link: str) -> None: ...

    def send_wallet_alert(self, *, recipient: str, event_id: str, code: str, severity: str,
                          incident_id: str | None = None, occurred_at: str | None = None,
                          diagnostics: dict | None = None) -> None: ...

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

    def send_email_otp(self, *, recipient: str, code: str, purpose: str) -> None:
        purposes = {
            'staff_activation_email': '客服后台首次开通',
            'email_rebind_old': '绑定手机',
            'password_reset_email': '更换登录密码',
            'email_bind_old_email': '验证原邮箱',
            'email_bind_new': '绑定新邮箱',
        }
        try:
            if purpose not in purposes or not isinstance(code, str) or re.fullmatch(r'[0-9]{6}', code) is None:
                raise ValueError('invalid email OTP')
            message = EmailMessage()
            message['Subject'] = '畅聊 ChatFlow ' + purposes[purpose] + '验证码'
            message['From'] = self._config.from_address
            message['To'] = recipient
            message.set_content(
                f'您正在进行{purposes[purpose]}。\n\n验证码：{code}\n'
                '验证码自申请起 5 分钟内有效。请勿向他人透露验证码。\n'
                '如非本人操作，请忽略此邮件。\n'
            )
            self._send(message)
        except Exception:
            raise EmailDeliveryError('SMTP email OTP delivery failed') from None

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

    def send_wallet_alert(self, *, recipient: str, event_id: str, code: str, severity: str,
                          incident_id: str | None = None, occurred_at: str | None = None,
                          diagnostics: dict | None = None) -> None:
        try:
            validate_wallet_alert_recipient(recipient)
            if (not self._config.use_starttls and not self._config.use_ssl
                    or not isinstance(event_id,str) or re.fullmatch('[A-Za-z0-9-]{1,36}',event_id) is None
                    or not isinstance(code,str) or re.fullmatch('[A-Z][A-Z0-9_]{0,99}',code) is None
                    or severity not in ('P0','P1','T2')):
                raise ValueError('invalid wallet alert')
            if incident_id is not None and (not isinstance(incident_id, str)
                    or re.fullmatch('[A-Za-z0-9-]{1,36}', incident_id) is None):
                raise ValueError('invalid wallet incident')
            when = '历史事件未记录详细时间'
            if occurred_at is not None:
                timestamp = datetime.fromisoformat(occurred_at.replace('Z', '+00:00'))
                if timestamp.tzinfo is None:
                    raise ValueError('aware alert timestamp required')
                when = timestamp.astimezone(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S') + ' 北京时间'
            context = validate_context(diagnostics) if diagnostics is not None else None
            problem = WALLET_PROBLEMS.get(code, '钱包监控发现异常，请核对事故记录')
            causes = ('历史事件未记录详细原因，不能仅凭事件码认定为网络故障。'
                      if context is None else '\n'.join(
                          '- ' + WALLET_REASONS[item] for item in context['failed_conditions'])
                      or WALLET_REASONS['UNKNOWN'])
            duration = (str(context['duration_seconds']) + ' 秒'
                        if context is not None and 'duration_seconds' in context else '未记录')
            initial = ('\n首次异常起因\n' + '\n'.join('- ' + WALLET_REASONS[item]
                for item in context['initial_conditions'])
                if context is not None and context.get('initial_conditions') else '')
            evidence = '\n'.join(f'{key}：{context[key]}' for key in (
                'observation_id', 'heartbeat_age_ms', 'observation_age_ms', 'solid_head_age_ms')
                if context is not None and key in context) or '无额外采样指标'
            message=EmailMessage()
            message['Subject']=f'畅聊 ChatFlow 钱包告警 [{severity}] {problem} ({code})'
            message['From']=self._config.from_address
            message['To']=recipient
            digest=hashlib.sha256(('wallet-alert:'+event_id).encode('ascii')).hexdigest()
            message['Message-ID']=f'<wallet-alert-{digest}@chatflow.invalid>'
            message.set_content(
                f'具体问题：{problem}\n等级：{severity}\n发生时间：{when}\n'
                f'事件 ID：{event_id}\n事故 ID：{incident_id or "历史事件未记录"}\n事件码：{code}\n'
                f'异常持续时间：{duration}\n\n触发原因与起因\n{causes}{initial}\n\n观察证据\n{evidence}\n\n'
                '操作影响\n此告警不会自动暂停钱包；全局暂停由管理员手动操作。'
                '已有暂停不会自动解除。证据不足的入账、出款或恢复操作仍会被各自校验拒绝。\n\n'
                '处理建议\n登录管理后台的“监控与事故”，按事故 ID 查看时间线和当前观察状态。'
                '若为短暂观察问题，核查数据源连接、观察进程及连续采样；'
                '若为差额、证据冲突或未知出款，请核对关联记录，必要时由管理员手动暂停。'
                '邮件反映事件发生时的证据，当前状态请以后台为准。\n')
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
