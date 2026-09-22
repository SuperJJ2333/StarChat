"""ADR-0077：人工充值应用服务。

- 用户提交申请：只生成 SUBMITTED 订单，不动任何余额；
- 客服/财务核实实际付款后走既有公开财务调整服务入账（审批链不变），
  再以 `mark_credited` 原子登记最终点钻金额与账本凭证；
- 同一到账凭证（evidence_txid）全局唯一，重复提交 409；
- 全部状态迁移写审计 + Outbox；不支持直改余额。
"""
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import hashlib
import json
from uuid import uuid4

from sqlalchemy import case, select
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.recharge.models import CsDirectoryEntry, RechargeCreditBinding, RechargeRequest

RECHARGE_RULES_VERSION = "recharge-manual-v1"


class RechargeService:
    def __init__(self, session_factory, *, ledger, rbac=None, rate_provider=None, now=None):
        self.factory = session_factory
        self.ledger = ledger
        self.rbac = rbac
        self.rate_provider = rate_provider
        self._now = now or (lambda: datetime.now(timezone.utc))

    def _utcnow(self):
        value = self._now()
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    @staticmethod
    def _amount(value, quantum):
        try:
            amount = Decimal(str(value))
            if (not amount.is_finite() or amount <= 0 or amount >= Decimal('1e16')
                    or amount != amount.quantize(Decimal(quantum))):
                raise ValueError
            return amount.quantize(Decimal(quantum))
        except (InvalidOperation, ValueError, TypeError):
            raise AppError(code='RECHARGE_AMOUNT_INVALID', message='充值金额或精度无效', status_code=422) from None

    def _claim(self, session, *, scope, key, payload, conflict_code='IDEMPOTENCY_KEY_REUSED'):
        """Claim and complete within the caller transaction, including on SQLite.

        The existing unique scope/key constraint serializes concurrent retries;
        an aborted business operation rolls its claim back as well.
        """
        if not isinstance(key, str) or not key.strip() or len(key) > 128:
            raise AppError(code='IDEMPOTENCY_KEY_REQUIRED', message='需要幂等键', status_code=422)
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        dialect = session.get_bind().dialect.name
        if dialect == 'postgresql':
            from sqlalchemy.dialects.postgresql import insert
        elif dialect == 'sqlite':
            from sqlalchemy.dialects.sqlite import insert
        else:
            raise ValueError('unsupported recharge database')
        inserted = session.execute(insert(IdempotencyRecord).values(id=str(uuid4()), scope=scope,
            idempotency_key=key, request_hash=digest, status='IN_PROGRESS', created_at=self._utcnow())
            .on_conflict_do_nothing(index_elements=['scope', 'idempotency_key'])
            .returning(IdempotencyRecord.id)).scalar_one_or_none() is not None
        record = session.scalar(select(IdempotencyRecord).where(IdempotencyRecord.scope == scope,
            IdempotencyRecord.idempotency_key == key).with_for_update())
        if record.request_hash != digest:
            raise AppError(code=conflict_code, message='幂等键或入账凭证已用于其他请求', status_code=409)
        if not inserted and record.status != 'COMPLETED':
            raise AppError(code='IDEMPOTENCY_IN_PROGRESS', message='请求正在处理中', status_code=409)
        return record

    def _complete(self, record, response, status=200):
        record.status, record.response_status = 'COMPLETED', status
        record.response_body, record.completed_at = response, self._utcnow()
        return response

    # ------------------------------------------------------------------ 用户
    def submit(self, *, user_id, amount_usdt, evidence_txid=None, note=None, idempotency_key=None):
        amount = self._amount(amount_usdt, '0.000001')
        if evidence_txid is not None:
            evidence_txid = evidence_txid.strip().lower()
            if not evidence_txid:
                evidence_txid = None
            elif len(evidence_txid) > 64:
                raise AppError(code="RECHARGE_EVIDENCE_INVALID", message="凭证号格式无效", status_code=422)
        rate = stale = None
        if self.rate_provider is not None:
            try:
                snapshot = self.rate_provider()
            except Exception:
                snapshot = None  # 参考汇率仅展示用：获取失败不阻塞申请单创建
            if snapshot is not None:
                rate, stale = Decimal(snapshot[0]), bool(snapshot[1])
        now = self._utcnow()
        request_id = str(uuid4())
        with self.factory.begin() as session:
            record = self._claim(session, scope='recharge.submit:'+user_id,
                key=idempotency_key if idempotency_key is not None else request_id,
                payload=dict(amount_usdt=str(amount), evidence_txid=evidence_txid, note=note or None))
            if record.status == 'COMPLETED':
                return record.response_body
            if evidence_txid is not None:
                existing = session.scalar(select(RechargeRequest.id).where(RechargeRequest.evidence_txid == evidence_txid))
                if existing is not None:
                    raise AppError(code="RECHARGE_EVIDENCE_REUSED", message="该到账凭证已用于其他充值申请", status_code=409)
            row = RechargeRequest(id=request_id, user_id=user_id, amount_usdt=amount,
                evidence_txid=evidence_txid, note=(note or None), status="SUBMITTED",
                fx_rate=rate, fx_rate_stale=stale, created_at=now, updated_at=now)
            session.add(row)
            try:
                session.flush()
            except IntegrityError:
                raise AppError(code="RECHARGE_EVIDENCE_REUSED", message="该到账凭证已用于其他充值申请", status_code=409) from None
            session.add(AuditEvent(id=str(uuid4()), actor_id=user_id, subject_type="recharge_request",
                subject_id=request_id, action="recharge.submitted", result="SUCCESS",
                reason_code="RECHARGE_SUBMIT", trace_id=(idempotency_key or request_id)[:32],
                after_data={"amount_usdt": str(amount), "has_evidence": evidence_txid is not None}, created_at=now))
            OutboxPublisher.enqueue(session, topic="recharge", event_type="recharge.submitted",
                aggregate_type="recharge_request", aggregate_id=request_id,
                payload={"request_id": request_id, "user_id": user_id}, now=now)
            return self._complete(record, self._view(row), 201)

    def cancel(self, *, user_id, request_id):
        with self.factory.begin() as session:
            row = session.scalar(select(RechargeRequest).where(RechargeRequest.id == request_id).with_for_update())
            if row is None or row.user_id != user_id:
                raise AppError(code="RECHARGE_NOT_FOUND", message="充值申请不存在", status_code=404)
            if row.status != "SUBMITTED":
                raise AppError(code="RECHARGE_CANNOT_CANCEL", message="当前状态不可取消", status_code=409)
            self._require_unbound(session, request_id)
            row.status, row.updated_at = "CANCELLED", self._utcnow()
            session.add(AuditEvent(id=str(uuid4()), actor_id=user_id, subject_type="recharge_request",
                subject_id=request_id, action="recharge.cancelled", result="SUCCESS",
                reason_code="RECHARGE_CANCEL", trace_id=request_id[:32], created_at=self._utcnow()))
            OutboxPublisher.enqueue(session, topic='recharge', event_type='recharge.cancelled',
                aggregate_type='recharge_request', aggregate_id=request_id,
                payload={'request_id': request_id}, now=self._utcnow())
            return self._view(row)

    def list_mine(self, *, user_id, limit=50):
        with self.factory() as session:
            rows = session.scalars(select(RechargeRequest).where(RechargeRequest.user_id == user_id)
                .order_by(RechargeRequest.created_at.desc(), RechargeRequest.id.desc()).limit(min(limit, 100))).all()
            return [self._view(row) for row in rows]

    # ------------------------------------------------------------------ 客服/管理
    def list_pending(self, *, limit=50):
        with self.factory() as session:
            rows = session.scalars(select(RechargeRequest).where(RechargeRequest.status == "SUBMITTED")
                .order_by(RechargeRequest.created_at, RechargeRequest.id).limit(min(limit, 100))).all()
            result = []
            for row in rows:
                view = self._view(row)
                binding = session.scalar(select(RechargeCreditBinding).where(
                    RechargeCreditBinding.request_id == row.id).order_by(
                        case((RechargeCreditBinding.state_active == '1', 0), else_=1), RechargeCreditBinding.created_at.desc()))
                view.update(binding_id=binding.id if binding else None,
                    binding_state=binding.state if binding else None,
                    binding_adjustment_id=binding.adjustment_id if binding else None,
                    binding_failure_reason=binding.failure_reason if binding else None,
                    binding_final_rate=str(binding.final_rate) if binding and binding.final_rate is not None else None,
                    binding_final_caibi_amount=str(binding.final_caibi_amount) if binding and binding.final_caibi_amount is not None else None)
                result.append(view)
            return result

    @staticmethod
    def _require_unbound(session, request_id):
        if session.scalar(select(RechargeCreditBinding.id).where(
                RechargeCreditBinding.request_id == request_id,
                RechargeCreditBinding.state_active == '1')) is not None:
            raise AppError(code='RECHARGE_CASE_BOUND', message='案件财务命令尚未完成核对', status_code=409)

    def reject(self, *, request_id, actor_id, reason, idempotency_key=None):
        if not reason or len(reason.strip()) < 3:
            raise AppError(code="RECHARGE_REASON_REQUIRED", message="拒绝必须填写原因", status_code=422)
        with self.factory.begin() as session:
            record = self._claim(session, scope='recharge.reject:'+actor_id,
                key=idempotency_key if idempotency_key is not None else request_id,
                payload=dict(request_id=request_id, reason=reason))
            if record.status == 'COMPLETED':
                return record.response_body
            row = session.scalar(select(RechargeRequest).where(RechargeRequest.id == request_id).with_for_update())
            if row is None:
                raise AppError(code="RECHARGE_NOT_FOUND", message="充值申请不存在", status_code=404)
            if row.status != "SUBMITTED":
                raise AppError(code="RECHARGE_ALREADY_DECIDED", message="该申请已处理", status_code=409)
            self._require_unbound(session, request_id)
            now = self._utcnow()
            row.status, row.decided_by, row.decided_at = "REJECTED", actor_id, now
            row.decision_reason = reason[:200]
            row.updated_at = now
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="recharge_request",
                subject_id=request_id, action="recharge.rejected", result="SUCCESS",
                reason_code='RECHARGE_REJECT', trace_id=(idempotency_key or request_id)[:32],
                after_data={'reason': reason[:200]}, created_at=now))
            OutboxPublisher.enqueue(session, topic="recharge", event_type="recharge.rejected",
                aggregate_type="recharge_request", aggregate_id=request_id,
                payload={"request_id": request_id}, now=now)
            return self._complete(record, self._view(row))

    def mark_credited(self, *, request_id, actor_id, ledger_transaction_id, final_caibi_amount,
                      final_rate=None, adjustment_id=None, idempotency_key=None):
        """客服核实到账、财务调整执行成功后登记 CREDITED（只登记，不再动账）。"""
        final_amount = self._amount(final_caibi_amount, '0.01')
        rate = self._amount(final_rate, '0.000001') if final_rate is not None else None
        now = self._utcnow()
        with self.factory.begin() as session:
            record = self._claim(session, scope='recharge.credit:'+actor_id,
                key=idempotency_key if idempotency_key is not None else request_id,
                payload=dict(request_id=request_id, ledger_transaction_id=ledger_transaction_id,
                    amount=str(final_amount), rate=str(rate) if rate is not None else None, adjustment_id=adjustment_id))
            if record.status == 'COMPLETED':
                return record.response_body
            row = session.scalar(select(RechargeRequest).where(RechargeRequest.id == request_id).with_for_update())
            if row is None:
                raise AppError(code="RECHARGE_NOT_FOUND", message="充值申请不存在", status_code=404)
            if row.status == "CREDITED":
                if (row.ledger_transaction_id != ledger_transaction_id or row.final_caibi_amount != final_amount
                        or rate is not None and row.final_rate != rate
                        or adjustment_id is not None and row.adjustment_id != adjustment_id):
                    raise AppError(code="RECHARGE_ALREADY_DECIDED", message="该申请已入账", status_code=409)
                return self._complete(record, self._view(row))
            if row.status != "SUBMITTED":
                raise AppError(code="RECHARGE_ALREADY_DECIDED", message="该申请已处理", status_code=409)
            # An explicit final settlement rate is required: a stale or missing
            # reference must never silently become a financial settlement.
            if rate is None:
                raise AppError(code='RECHARGE_FINAL_RATE_REQUIRED', message='请填写最终结算汇率', status_code=422)
            if (row.amount_usdt * rate).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP) != final_amount:
                raise AppError(code='RECHARGE_SETTLEMENT_MISMATCH', message='最终金额与结算汇率不一致', status_code=422)
            proof = self._claim(session, scope='recharge.credit_transaction', key=ledger_transaction_id,
                payload={'request_id': request_id}, conflict_code='RECHARGE_PROOF_REUSED')
            if session.scalar(select(RechargeRequest.id).where(
                    RechargeRequest.ledger_transaction_id == ledger_transaction_id,
                    RechargeRequest.id != request_id)) is not None:
                raise AppError(code='RECHARGE_PROOF_REUSED', message='入账凭证已用于其他申请', status_code=409)
            query = select(AdjustmentRequest).where(AdjustmentRequest.ledger_transaction_id == ledger_transaction_id)
            if adjustment_id is not None:
                query = query.where(AdjustmentRequest.id == adjustment_id)
            adjustments = session.scalars(query.with_for_update()).all()
            adjustment = adjustments[0] if len(adjustments) == 1 else None
            bindings = list(session.scalars(select(RechargeCreditBinding).where(
                RechargeCreditBinding.state_active == '1',
                (RechargeCreditBinding.request_id == request_id) |
                (RechargeCreditBinding.adjustment_id == (adjustment.id if adjustment else adjustment_id)))))
            if any(item.request_id != request_id or adjustment is None or
                   item.adjustment_id != adjustment.id for item in bindings):
                raise AppError(code='RECHARGE_CASE_BOUND', message='凭证与案件持久绑定不一致', status_code=409)
            binding = bindings[0] if bindings else None
            if binding and ((binding.final_rate is not None and binding.final_rate != rate) or
                    (binding.final_caibi_amount is not None and binding.final_caibi_amount != final_amount)):
                raise AppError(code='RECHARGE_SETTLEMENT_MISMATCH', message='最终金额与绑定结算快照不一致', status_code=409)
            tx = self.ledger.lock_transaction(session=session, transaction_id=ledger_transaction_id)
            if (adjustment is None or adjustment.status != 'EXECUTED' or adjustment.user_id != row.user_id
                    or adjustment.amount != final_amount or not (adjustment.finance_reviewer_id or adjustment.admin_reviewer_id)
                    or tx is None or tx.asset != 'CAIBI' or tx.scope != 'ledger.adjustment'
                    or tx.idempotency_key != 'adjustment-execute:'+adjustment.id
                    or tx.reason_code != adjustment.reason_code or tx.reversal_of_id is not None
                    or session.scalar(select(LedgerTransaction.id).where(LedgerTransaction.reversal_of_id == tx.id))):
                raise AppError(code='RECHARGE_PROOF_INVALID', message='需要已审批执行且匹配的财务调整凭证', status_code=409)
            entries = list(session.scalars(select(LedgerEntry).where(LedgerEntry.transaction_id == tx.id)))
            if (len(entries) != 2 or any(entry.asset != 'CAIBI' for entry in entries)
                    or {entry.account_id: entry.amount for entry in entries} != {
                        row.user_id: final_amount, 'PLATFORM_CLEARING': -final_amount}):
                raise AppError(code='RECHARGE_PROOF_INVALID', message='财务调整分录不匹配', status_code=409)
            row.status = "CREDITED"
            row.decided_by, row.decided_at = actor_id, now
            row.final_rate = rate
            row.final_caibi_amount = final_amount
            row.ledger_transaction_id = ledger_transaction_id
            row.adjustment_id = adjustment.id
            row.updated_at = now
            if binding:
                self._transition_binding(session, binding, 'REGISTERED', None, actor_id)
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="recharge_request",
                subject_id=request_id, action="recharge.credited", result="SUCCESS",
                reason_code="RECHARGE_CREDIT", trace_id=(idempotency_key or request_id)[:32],
                after_data={"final_caibi_amount": str(final_amount),
                    "ledger_transaction_id": ledger_transaction_id}, created_at=now))
            OutboxPublisher.enqueue(session, topic="recharge", event_type="recharge.credited",
                aggregate_type="recharge_request", aggregate_id=request_id,
                payload={"request_id": request_id, "user_id": row.user_id,
                    "final_caibi_amount": str(final_amount)}, now=now)
            self._complete(proof, {'request_id': request_id})
            return self._complete(record, self._view(row))

    # ------------------------------------------------------------------ 目录
    def directory(self, *, include_disabled=False):
        with self.factory() as session:
            statement = select(CsDirectoryEntry).order_by(CsDirectoryEntry.sort, CsDirectoryEntry.created_at)
            if not include_disabled:
                statement = statement.where(CsDirectoryEntry.enabled.is_(True))
            return [self._directory_view(row) for row in session.scalars(statement).all()]

    def upsert_directory_entry(self, *, actor_id, entry_id=None, cs_user_id, display_name,
                               payment_address, note=None, enabled=True, sort=0):
        from app.modules.identity.models import User

        now = self._utcnow()
        with self.factory.begin() as session:
            if session.scalar(select(User.id).where(User.id == cs_user_id)) is None:
                raise AppError(code="RECHARGE_CS_USER_NOT_FOUND", message="客服账号不存在", status_code=422)
            row = session.get(CsDirectoryEntry, entry_id, with_for_update=True) if entry_id else None
            if entry_id is not None and row is None:
                raise AppError(code='RECHARGE_DIRECTORY_NOT_FOUND', message='客服目录条目不存在', status_code=404)
            if row is None:
                row = CsDirectoryEntry(id=str(uuid4()), created_at=now)
                session.add(row)
            row.cs_user_id, row.display_name = cs_user_id, display_name[:64]
            row.payment_address, row.note = payment_address[:128], (note or None)
            row.enabled, row.sort, row.updated_at = bool(enabled), int(sort), now
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="cs_directory_entry",
                subject_id=row.id, action="recharge.directory_updated", result="SUCCESS",
                reason_code="RECHARGE_DIRECTORY", trace_id=row.id[:32], created_at=now))
            OutboxPublisher.enqueue(session, topic='recharge', event_type='recharge.directory_updated',
                aggregate_type='cs_directory_entry', aggregate_id=row.id,
                payload={'entry_id': row.id, 'enabled': row.enabled}, now=now)
            return self._directory_view(row)

    # ---------------------------------------------------- 案件-财务执行绑定
    def bind_finance_adjustment(self, *, request_id, adjustment_id, actor_id, idempotency_key=None, final_rate=None):
        """把 SUBMITTED 案件绑定到唯一授权财务调整（不入账、不改余额）。

        绑定校验：调整归属同一用户、未被冲正、仍在审批中；案件 SUBMITTED；
        双方当前均无活动绑定。执行仍走既有公开财务审批/执行链路；登记由
        `complete_bound`（worker 幂等恢复或人工入口）在执行后完成。
        """
        now = self._utcnow()
        rate = self._amount(final_rate, '0.000001') if final_rate is not None else None
        with self.factory.begin() as session:
            record = self._claim(session, scope='recharge.bind:' + actor_id,
                key=idempotency_key if idempotency_key is not None else request_id + ':' + adjustment_id,
                payload=dict(request_id=request_id, adjustment_id=adjustment_id, final_rate=str(rate) if rate is not None else None))
            if record.status == 'COMPLETED':
                return record.response_body
            row = session.scalar(select(RechargeRequest).where(RechargeRequest.id == request_id).with_for_update())
            if row is None:
                raise AppError(code='RECHARGE_NOT_FOUND', message='充值申请不存在', status_code=404)
            if row.status != 'SUBMITTED':
                raise AppError(code='RECHARGE_ALREADY_DECIDED', message='该申请已处理', status_code=409)
            active = session.scalar(select(RechargeCreditBinding).where(
                RechargeCreditBinding.request_id == request_id,
                RechargeCreditBinding.state_active == '1').with_for_update())
            if active is not None:
                if active.adjustment_id == adjustment_id:
                    if active.final_rate != rate:
                        raise AppError(code='RECHARGE_SETTLEMENT_MISMATCH', message='绑定结算率不可替换', status_code=409)
                    return self._complete(record, self._binding_view(active))
                raise AppError(code='RECHARGE_CASE_BOUND', message='案件已绑定其他财务命令', status_code=409)
            taken = session.scalar(select(RechargeCreditBinding.id).where(
                RechargeCreditBinding.adjustment_id == adjustment_id,
                RechargeCreditBinding.state_active == '1'))
            if taken is not None:
                raise AppError(code='RECHARGE_ADJUSTMENT_BOUND', message='该财务命令已绑定其他案件', status_code=409)
            from app.modules.ledger.adjustment_models import AdjustmentRequest

            adjustment = session.get(AdjustmentRequest, adjustment_id, with_for_update=True)
            if adjustment is None or adjustment.user_id != row.user_id:
                raise AppError(code='RECHARGE_PROOF_INVALID', message='财务调整与申请用户不匹配', status_code=409)
            # Recheck after locking the command: another case may have bound it
            # while this transaction waited for its authoritative row lock.
            if session.scalar(select(RechargeCreditBinding.id).where(
                    RechargeCreditBinding.adjustment_id == adjustment_id,
                    RechargeCreditBinding.state_active == '1')) is not None:
                raise AppError(code='RECHARGE_ADJUSTMENT_BOUND', message='该财务命令已绑定其他案件', status_code=409)
            if adjustment.status not in ('SUBMITTED', 'FINANCE_APPROVED', 'ADMIN_APPROVED'):
                raise AppError(code='RECHARGE_BIND_TERMINAL_ADJUSTMENT',
                    message='只能绑定尚在审批中的财务调整', status_code=409)
            amount = self._amount(adjustment.amount, '0.01')
            if rate is not None and (row.amount_usdt * rate).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP) != amount:
                raise AppError(code='RECHARGE_SETTLEMENT_MISMATCH', message='金额与绑定结算率不一致', status_code=409)
            if (adjustment.ledger_transaction_id is not None
                    and session.scalar(select(LedgerTransaction.id).where(
                        LedgerTransaction.reversal_of_id == adjustment.ledger_transaction_id)) is not None):
                raise AppError(code='RECHARGE_PROOF_INVALID', message='财务调整已被冲正', status_code=409)
            binding = RechargeCreditBinding(id=str(uuid4()), request_id=request_id,
                adjustment_id=adjustment_id, state='BOUND', state_active='1',
                final_rate=rate, final_caibi_amount=amount,
                bound_by=actor_id, created_at=now, updated_at=now)
            session.add(binding)
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='recharge_credit_binding',
                subject_id=binding.id, action='recharge.binding_created', result='SUCCESS',
                reason_code='RECHARGE_BIND', trace_id=(idempotency_key or binding.id)[:32],
                after_data={'request_id': request_id, 'adjustment_id': adjustment_id,
                    'final_rate': str(rate) if rate is not None else None,
                    'final_caibi_amount': str(amount)}, created_at=now))
            OutboxPublisher.enqueue(session, topic='recharge', event_type='recharge.bound',
                aggregate_type='recharge_credit_binding', aggregate_id=binding.id,
                payload={'request_id': request_id, 'adjustment_id': adjustment_id}, now=now)
            return self._complete(record, self._binding_view(binding))

    def _transition_binding(self, session, binding, state, reason, actor_id):
        if binding.state == state and binding.failure_reason == reason:
            return
        binding.state = state
        binding.state_active = '1' if state in ('BOUND', 'NEEDS_REVIEW') else None
        binding.failure_reason = reason
        binding.updated_at = self._utcnow()
        action = 'recharge.binding_' + state.lower()
        session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id,
            subject_type='recharge_credit_binding', subject_id=binding.id,
            action=action, result='SUCCESS', reason_code='RECHARGE_BIND_' + state,
            trace_id=binding.id[:32], after_data={'state': state, 'reason': reason},
            created_at=binding.updated_at))
        OutboxPublisher.enqueue(session, topic='recharge', event_type=action,
            aggregate_type='recharge_credit_binding', aggregate_id=binding.id,
            payload={'request_id': binding.request_id, 'state': state, 'reason': reason},
            now=binding.updated_at)

    def complete_bound(self, *, request_id, actor_id='recharge-registration-worker', expected_binding_id=None):
        """Register executed money; uncertain settlement never releases the command."""
        with self.factory.begin() as session:
            row = session.get(RechargeRequest, request_id, with_for_update=True)
            binding = session.scalar(select(RechargeCreditBinding).where(
                RechargeCreditBinding.request_id == request_id,
                RechargeCreditBinding.state_active == '1').with_for_update())
            if expected_binding_id is not None and (binding is None or binding.id != expected_binding_id):
                previous = session.get(RechargeCreditBinding, expected_binding_id)
                if (binding is None and row is not None and row.status == 'CREDITED' and previous is not None
                        and previous.request_id == request_id and previous.state == 'REGISTERED'):
                    return {'status': 'CREDITED', 'binding_state': 'REGISTERED'}
                raise AppError(code='RECHARGE_BINDING_CHANGED', message='绑定已变化，请刷新后重试', status_code=409)
            if binding is None:
                if row is not None and row.status == 'CREDITED':
                    return {'status': 'CREDITED', 'binding_state': 'REGISTERED'}
                raise AppError(code='RECHARGE_BINDING_NOT_FOUND', message='案件没有待登记的绑定', status_code=404)
            adjustment = session.get(AdjustmentRequest, binding.adjustment_id, with_for_update=True)
            if adjustment is None:
                self._transition_binding(session, binding, 'NEEDS_REVIEW', 'RECHARGE_ADJUSTMENT_MISSING', actor_id)
                return {'status': row.status, 'binding_state': 'NEEDS_REVIEW'}
            if adjustment.status == 'REJECTED':
                evidence = self._release_evidence(session, adjustment)
                state = 'FAILED' if evidence else 'NEEDS_REVIEW'
                self._transition_binding(session, binding, state, evidence or 'RECHARGE_PROOF_INVALID', actor_id)
                return {'status': row.status, 'binding_state': state}
            if adjustment.status != 'EXECUTED' or not adjustment.ledger_transaction_id:
                return {'status': 'PENDING_APPROVAL', 'binding_state': binding.state}
            binding_id = binding.id
            adjustment_id, adjustment_amount, adjustment_tx = adjustment.id, adjustment.amount, adjustment.ledger_transaction_id
            rate = binding.final_rate
        try:
            result = self.mark_credited(request_id=request_id, actor_id=actor_id,
                ledger_transaction_id=adjustment_tx, final_caibi_amount=adjustment_amount,
                final_rate=rate if rate is not None else self._derived_rate(request_id, adjustment_amount),
                adjustment_id=adjustment_id, idempotency_key='register:' + binding_id)
        except AppError as error:
            with self.factory.begin() as session:
                session.get(RechargeRequest, request_id, with_for_update=True)
                binding = session.get(RechargeCreditBinding, binding_id, with_for_update=True)
                if binding is not None and binding.state_active == '1':
                    self.ledger.lock_transaction(session=session, transaction_id=adjustment_tx)
                    reversed_tx = session.scalar(select(LedgerTransaction.id).where(
                        LedgerTransaction.reversal_of_id == adjustment_tx))
                    self._transition_binding(session, binding,
                        'FAILED' if reversed_tx else 'NEEDS_REVIEW', error.code, actor_id)
            raise
        return {**result, 'binding_state': 'REGISTERED'}

    def _derived_rate(self, request_id: str, final_amount):
        """由已执行金额反推六位结算率；不能精确反推时返回 None
        （mark_credited 将要求人工提供最终汇率，绝不伪造资金事实）。"""
        from decimal import ROUND_HALF_UP

        with self.factory() as session:
            row = session.get(RechargeRequest, request_id)
        if row is None or not row.amount_usdt:
            return None
        try:
            rate = (Decimal(str(final_amount)) / row.amount_usdt).quantize(
                Decimal('0.000001'), rounding=ROUND_HALF_UP)
        except Exception:
            return None
        check = (row.amount_usdt * rate).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)
        return str(rate) if check == Decimal(str(final_amount)).quantize(Decimal('0.01')) else None

    def sweep_pending_registrations(self, *, limit: int = 100, actor_id='recharge-registration-worker') -> dict:
        """worker 兜底：BOUND 绑定逐一尝试幂等登记（执行后宕机恢复）。"""
        with self.factory() as session:
            ids = list(session.scalars(select(RechargeCreditBinding.request_id).where(
                RechargeCreditBinding.state == 'BOUND').outerjoin(AdjustmentRequest, AdjustmentRequest.id == RechargeCreditBinding.adjustment_id).order_by(
                    case((AdjustmentRequest.status.in_(('EXECUTED', 'REJECTED')), 0), else_=1),
                    RechargeCreditBinding.updated_at, RechargeCreditBinding.id).limit(limit)))
        completed = failed = pending = 0
        for request_id in ids:
            try:
                result = self.complete_bound(request_id=request_id, actor_id=actor_id)
            except AppError as error:
                if error.code in ('RECHARGE_PROOF_INVALID', 'RECHARGE_PROOF_REUSED',
                        'RECHARGE_SETTLEMENT_MISMATCH', 'RECHARGE_FINAL_RATE_REQUIRED'):
                    failed += 1
                else:
                    pending += 1
                continue
            if result.get('binding_state') in ('BOUND', 'NEEDS_REVIEW'):
                pending += 1
            elif result.get('binding_state') == 'FAILED':
                failed += 1
            else:
                completed += 1
        return {'scanned': len(ids), 'completed': completed, 'failed': failed, 'pending': pending}

    # ---------------------------------------------------- 待核对处置（ADR-0077）
    @staticmethod
    def _parse_cursor(cursor):
        if not isinstance(cursor, str) or cursor.count('|') != 1:
            raise AppError(code='RECHARGE_CURSOR_INVALID', message='分页游标无效', status_code=400)
        when, row_id = cursor.split('|')
        try:
            if not row_id or len(row_id) > 36 or 'T' not in when:
                raise ValueError
            timestamp = datetime.fromisoformat(when)
        except ValueError:
            raise AppError(code='RECHARGE_CURSOR_INVALID', message='分页游标无效', status_code=400) from None
        return timestamp, row_id

    def review_queue(self, *, limit: int = 50) -> list[dict]:
        return self.review_queue_page(limit=limit)['items']

    def review_queue_page(self, *, cursor=None, limit: int = 50) -> dict:
        limit = max(1, min(int(limit), 100))
        with self.factory() as session:
            statement = select(RechargeCreditBinding).where(
                RechargeCreditBinding.state == 'NEEDS_REVIEW',
                RechargeCreditBinding.state_active == '1').order_by(
                    RechargeCreditBinding.created_at, RechargeCreditBinding.id)
            if cursor:
                when, row_id = self._parse_cursor(cursor)
                statement = statement.where((RechargeCreditBinding.created_at > when) |
                    ((RechargeCreditBinding.created_at == when) & (RechargeCreditBinding.id > row_id)))
            rows = list(session.scalars(statement.limit(limit + 1)))
            page = rows[:limit]
            items = []
            for binding in page:
                request = session.get(RechargeRequest, binding.request_id)
                items.append({**self._binding_view(binding),
                    'request_status': request.status if request else None,
                    'user_id': request.user_id if request else None,
                    'amount_usdt': str(request.amount_usdt) if request else None})
            next_cursor = page[-1].created_at.isoformat() + '|' + page[-1].id if len(rows) > limit else None
            return {'items': items, 'next_cursor': next_cursor}

    def admin_requests(self, *, status=None, cursor=None, limit: int = 50) -> dict:
        """Stable case pagination with current or most recent historical binding."""
        limit = max(1, min(int(limit), 100))
        with self.factory() as session:
            statement = select(RechargeRequest).order_by(
                RechargeRequest.created_at.desc(), RechargeRequest.id.desc())
            if status:
                statement = statement.where(RechargeRequest.status == status)
            if cursor:
                when, row_id = self._parse_cursor(cursor)
                statement = statement.where((RechargeRequest.created_at < when) |
                    ((RechargeRequest.created_at == when) & (RechargeRequest.id < row_id)))
            rows = session.scalars(statement.limit(limit + 1)).all()
            page = rows[:limit]
            bindings = {}
            for binding in session.scalars(select(RechargeCreditBinding).where(
                    RechargeCreditBinding.request_id.in_([row.id for row in page])).order_by(
                    case((RechargeCreditBinding.state_active == '1', 0), else_=1),
                    RechargeCreditBinding.created_at.desc(), RechargeCreditBinding.id.desc())):
                bindings.setdefault(binding.request_id, binding)
            next_cursor = page[-1].created_at.isoformat() + '|' + page[-1].id if len(rows) > limit else None
            return {'items': [{**self._view(row),
                'binding_state': bindings[row.id].state if row.id in bindings else None,
                'binding_id': bindings[row.id].id if row.id in bindings else None} for row in page],
                'next_cursor': next_cursor}

    def case_timeline(self, *, request_id: str) -> dict:
        """案件审计时间线：案件/绑定维度的全部审计事件（只读）。"""
        with self.factory() as session:
            row = session.get(RechargeRequest, request_id)
            if row is None:
                raise AppError(code='RECHARGE_NOT_FOUND', message='充值申请不存在', status_code=404)
            binding_ids = list(session.scalars(select(RechargeCreditBinding.id).where(
                RechargeCreditBinding.request_id == request_id)))
            from sqlalchemy import or_

            events = session.scalars(select(AuditEvent).where(or_(
                (AuditEvent.subject_type == 'recharge_request') & (AuditEvent.subject_id == request_id),
                (AuditEvent.subject_type == 'recharge_credit_binding') & (AuditEvent.subject_id.in_(binding_ids or [''])),
            )).order_by(AuditEvent.created_at, AuditEvent.id)).all()
            return {'request_id': request_id, 'status': row.status,
                'items': [{'at': e.created_at.isoformat() if e.created_at else None, 'actor': e.actor_id,
                    'action': e.action, 'reason_code': e.reason_code,
                    'after': e.after_data} for e in events]}

    def retry_review_registration(self, *, request_id: str, actor_id: str, expected_binding_id=None) -> dict:
        return self.complete_bound(request_id=request_id, actor_id=actor_id,
            expected_binding_id=expected_binding_id)

    def _release_evidence(self, session, adjustment):
        """Missing commands or contradictory financial records are not unpaid proof."""
        if adjustment is None:
            return None
        transaction = session.scalar(select(LedgerTransaction).where(
            LedgerTransaction.scope == 'ledger.adjustment',
            LedgerTransaction.idempotency_key == 'adjustment-execute:' + adjustment.id))
        if transaction is None:
            return 'ADJUSTMENT_REJECTED' if adjustment.status == 'REJECTED' and not adjustment.ledger_transaction_id else None
        if adjustment.ledger_transaction_id and adjustment.ledger_transaction_id != transaction.id:
            return None
        self.ledger.lock_transaction(session=session, transaction_id=transaction.id)
        return 'ADJUSTMENT_REVERSED' if session.scalar(select(LedgerTransaction.id).where(
            LedgerTransaction.reversal_of_id == transaction.id)) is not None else None

    def release_review_binding(self, *, request_id: str, actor_id: str, reason: str,
                               idempotency_key=None, expected_binding_id=None) -> dict:
        """Release only verified rejected/unpaid or reversed commands, never missing evidence."""
        if not reason or len(reason.strip()) < 3:
            raise AppError(code='RECHARGE_REASON_REQUIRED', message='释放必须填写原因', status_code=422)
        now = self._utcnow()
        with self.factory.begin() as session:
            row = session.get(RechargeRequest, request_id, with_for_update=True)
            if row is None:
                raise AppError(code='RECHARGE_NOT_FOUND', message='充值申请不存在', status_code=404)
            binding = session.scalar(select(RechargeCreditBinding).where(
                RechargeCreditBinding.request_id == request_id,
                RechargeCreditBinding.state_active == '1').with_for_update())
            identity = expected_binding_id or (binding.id if binding else None)
            if identity is None and idempotency_key is None:
                prior = session.scalar(select(RechargeCreditBinding).where(
                    RechargeCreditBinding.request_id == request_id).order_by(
                        RechargeCreditBinding.created_at.desc(), RechargeCreditBinding.id.desc()))
                identity = prior.id if prior else None
            record = self._claim(session, scope='recharge.review.release:' + actor_id,
                key=idempotency_key if idempotency_key is not None else 'release:' + (identity or request_id),
                payload={'request_id': request_id, 'reason': reason.strip(), 'expected_binding_id': expected_binding_id})
            if record.status == 'COMPLETED':
                return record.response_body
            if expected_binding_id is not None and (binding is None or binding.id != expected_binding_id):
                raise AppError(code='RECHARGE_BINDING_CHANGED', message='绑定已变化，请刷新后重试', status_code=409)
            if binding is None:
                raise AppError(code='RECHARGE_BINDING_NOT_FOUND', message='案件没有待核对的绑定', status_code=404)
            if binding.state != 'NEEDS_REVIEW' or row.status != 'SUBMITTED':
                raise AppError(code='RECHARGE_RELEASE_NOT_ALLOWED', message='仅待核对且未登记案件可释放', status_code=409)
            adjustment = session.get(AdjustmentRequest, binding.adjustment_id, with_for_update=True)
            evidence = self._release_evidence(session, adjustment)
            if evidence is None:
                raise AppError(code='RECHARGE_RELEASE_EVIDENCE_REQUIRED', message='资金事实未核实，不得释放', status_code=409)
            self._transition_binding(session, binding, 'FAILED', f'{evidence}:{reason.strip()[:120]}', actor_id)
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='recharge_credit_binding',
                subject_id=binding.id, action='recharge.binding_released', result='SUCCESS',
                reason_code=evidence, trace_id=binding.id[:32],
                after_data={'request_id': request_id, 'reason': reason.strip()[:120]}, created_at=now))
            OutboxPublisher.enqueue(session, topic='recharge', event_type='recharge.binding_released',
                aggregate_type='recharge_credit_binding', aggregate_id=binding.id,
                payload={'request_id': request_id, 'evidence': evidence}, now=now)
            return self._complete(record, self._binding_view(binding))

    @staticmethod
    def _binding_view(row) -> dict:
        return {'id': row.id, 'request_id': row.request_id, 'adjustment_id': row.adjustment_id,
            'state': row.state, 'bound_by': row.bound_by,
            'final_rate': str(row.final_rate) if row.final_rate is not None else None,
            'final_caibi_amount': str(row.final_caibi_amount) if row.final_caibi_amount is not None else None,
            'failure_reason': row.failure_reason,
            'created_at': row.created_at.isoformat() if row.created_at else None}

    # ------------------------------------------------------------------ 投影
    @staticmethod
    def _view(row) -> dict:
        return {"id": row.id, "user_id": row.user_id, "amount_usdt": str(row.amount_usdt),
            "evidence_txid": row.evidence_txid, "note": row.note, "status": row.status,
            "fx_rate": str(row.fx_rate) if row.fx_rate is not None else None,
            "fx_rate_stale": row.fx_rate_stale,
            "decided_by": row.decided_by, "decided_at": row.decided_at.isoformat() if row.decided_at else None,
            "decision_reason": row.decision_reason,
            "final_rate": str(row.final_rate) if row.final_rate is not None else None,
            "final_caibi_amount": str(row.final_caibi_amount) if row.final_caibi_amount is not None else None,
            "ledger_transaction_id": row.ledger_transaction_id, "adjustment_id": row.adjustment_id,
            "rules_version": RECHARGE_RULES_VERSION,
            "created_at": row.created_at.isoformat() if row.created_at else None}

    @staticmethod
    def _directory_view(row) -> dict:
        return {"id": row.id, "cs_user_id": row.cs_user_id, "display_name": row.display_name,
            "payment_address": row.payment_address, "note": row.note, "enabled": row.enabled, "sort": row.sort}
