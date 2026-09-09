"""Durable internal close revisions, sealed over one captured ledger entry set."""
from contextlib import nullcontext
from datetime import date, datetime, timezone
import hashlib
import hmac
import json
import re
from uuid import uuid4

from sqlalchemy import select, text

from app.core.errors import AppError
from app.modules.wallet.closing_models import WalletDailyClose
from app.modules.wallet.reporting import REPORT_TIMEZONE, WalletReportService, _iso, _utc
from app.modules.wallet.safety import audit_write


def _integrity_error():
    return AppError(code='WALLET_CLOSE_INTEGRITY', message='Closed report integrity verification failed', status_code=409)


def _verify(report, digest):
    if not isinstance(report, dict):
        raise _integrity_error()
    evidence = {key: value for key, value in report.items() if key != 'digest'}
    actual = hashlib.sha256(json.dumps(evidence, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')).hexdigest()
    if (not isinstance(digest, str) or not hmac.compare_digest(actual, digest)
            or report.get('digest') != digest or report.get('finalized') is not False
            or report.get('integrity', {}).get('balanced') is not True):
        raise _integrity_error()


class WalletClosingService:
    def __init__(self, factory, now_factory=None):
        self.factory = factory
        self.now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def close(self, day, actor_id, reason_code, idempotency_key):
        now = _utc(self.now_factory())
        if type(day) is not date or day >= now.astimezone(REPORT_TIMEZONE).date():
            raise ValueError('close day must be in the past in Hong Kong')
        if (not isinstance(actor_id, str) or not 1 <= len(actor_id) <= 36 or actor_id.strip() != actor_id
                or not isinstance(reason_code, str) or not re.fullmatch(r'[A-Z][A-Z0-9_]{0,99}', reason_code)
                or not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key) <= 128
                or idempotency_key.strip() != idempotency_key):
            raise ValueError('valid actor, reason and idempotency key required')
        with self.factory() as session, session.begin():
            dialect = session.get_bind().dialect.name
            # Global close namespace also serializes key collisions across days.
            # A fresh SQLite session must acquire its write reservation before reads.
            if dialect == 'postgresql':
                session.execute(text('SELECT pg_advisory_xact_lock(1464025932, 1)'))
            elif dialect == 'sqlite':
                session.execute(text('BEGIN IMMEDIATE'))
            else:
                raise ValueError('unsupported close database')
            existing = session.scalar(select(WalletDailyClose).where(WalletDailyClose.idempotency_key == idempotency_key))
            if existing is not None:
                if (existing.day, existing.created_by, existing.reason_code) != (day, actor_id, reason_code):
                    raise AppError(code='IDEMPOTENCY_CONFLICT', message='Close key reused with different payload', status_code=409)
                return self._result(existing)
            previous = session.scalar(select(WalletDailyClose).where(WalletDailyClose.day == day)
                                      .order_by(WalletDailyClose.revision.desc()).limit(1))
            # Reuse the single-query public reporter inside this transaction;
            # nullcontext prevents the reporter from closing our owned session.
            report = WalletReportService(lambda: nullcontext(session)).daily(day)
            _verify(report, report['digest'])
            row = WalletDailyClose(id=str(uuid4()), day=day, revision=previous.revision + 1 if previous else 1,
                previous_id=previous.id if previous else None, digest=report['digest'], report=report,
                created_by=actor_id, created_at=now, reason_code=reason_code, idempotency_key=idempotency_key)
            session.add(row)
            audit_write(session, actor_id, row.id, 'wallet.daily_closed', reason_code)
            session.flush()
            return self._result(row)

    def get(self, id):
        with self.factory() as session:
            row = session.get(WalletDailyClose, id)
            if row is None:
                raise AppError(code='WALLET_CLOSE_NOT_FOUND', message='Closed report not found', status_code=404)
            return self._result(row)

    @staticmethod
    def _result(row):
        _verify(row.report, row.digest)
        if row.report.get('day') != row.day.isoformat():
            raise _integrity_error()
        return dict(id=row.id, day=row.day.isoformat(), revision=row.revision, previous_id=row.previous_id,
                    digest=row.digest, created_by=row.created_by, created_at=_iso(row.created_at),
                    cutoff_kind='CAPTURED_ENTRY_SET', report=row.report)
