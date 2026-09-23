"""ADR-0079 实施补充：群主转让持久协调（Matrix 应用 + 财务换主两阶段）。

核心约束（复审确认的缺口）：
- HTTP 请求与"Matrix 权限变更 + 业务注册表换主"不是也不可能是同一个
  事务；因此转让是一个**持久、可恢复的阶段机**，而不是单事务声明成功。
- Matrix 侧变更通过网关既有能力完成：Synapse admin login-as-user 换取
  短期用户 token（invite 链路已在用），再以群主身份发送
  m.room.power_levels；成败以随后的**权威房间状态读取**为准。
- 事务边界：
  T1 建意图（领域校验通过，stage=VALIDATED）；
  T2 认领（条件 UPDATE → MATRIX_PENDING，含随机 claim_token 防过期持有者写回）；
  — 网络 I/O 在事务外 —
  T3 权威状态确认 → MATRIX_APPLIED；发送结果不确定保留 MATRIX_PENDING，
    恢复只读确认，不自动重发；无法确认则 NEEDS_REVIEW；
  T4 条件更新注册表（WHERE owner=旧群主）+ owner_since=now + COMPLETED；
    条件不满足（并发/漂移）→ NEEDS_REVIEW。
- 崩溃恢复：MATRIX_PENDING 认领超时后，worker 先读权威状态——上一进程
  若已应用（崩溃在 T3 前）直接推进 MATRIX_APPLIED→COMPLETED；无法证实
  已应用则 NEEDS_REVIEW。仅确定尚未发送的准备失败允许有限重试。
- 防守：任何阶段都不给客户端"虚假成功"；只有 COMPLETED 才报告新群主。
"""
from datetime import datetime, timedelta, timezone
from copy import deepcopy
from hashlib import sha256
import json
import secrets
from uuid import uuid4

from sqlalchemy import select, update, or_

from app.core.errors import AppError
from app.modules.groups.models import BusinessGroup, GroupTransferIntent
from app.modules.groups.registry import (
    COOLDOWN_MIN_MEMBERS,
    COOLDOWN_PERIOD,
    CREATOR_POWER,
    GroupOwnerError,
    matrix_owner_from_state,
)

CLAIM_TIMEOUT_SECONDS = 60
DEFAULT_MAX_ATTEMPTS = 3
STAGE_VALIDATED = "VALIDATED"
STAGE_MATRIX_PENDING = "MATRIX_PENDING"
STAGE_MATRIX_APPLIED = "MATRIX_APPLIED"
STAGE_COMPLETED = "COMPLETED"
STAGE_NEEDS_REVIEW = "NEEDS_REVIEW"
STAGE_FAILED = "FAILED"
SAFE_RELEASE_REASON = "REVIEW_CONFIRMED_NOT_SENT"


class GroupTransferCoordinator:
    def __init__(self, session_factory, *, registry, matrix_gateway, now=None,
                 max_attempts: int = DEFAULT_MAX_ATTEMPTS):
        self._factory = session_factory
        self.registry = registry
        self._gateway = matrix_gateway
        self._now = now or (lambda: datetime.now(timezone.utc))
        self.max_attempts = int(max_attempts)

    def _utcnow(self) -> datetime:
        value = self._now()
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)

    # ------------------------------------------------------------- 领域校验
    def _validate_domain(self, *, room_id, current_owner_user_id, new_owner_user_id, group=None):
        """只读领域校验（与 registry.transfer 相同规则；不落任何变更）。"""
        from app.modules.identity.models import User
        from app.modules.identity.enums import AccountStatus
        try:
            members = set(self._gateway.get_room_members(room_id))
            state = self._gateway.get_room_state(room_id)
        except Exception:
            raise GroupOwnerError('GROUP_AUTHORITY_UNAVAILABLE', '群权威状态暂不可用') from None
        with self._factory() as session:
            owners = {u.id: u for u in session.scalars(select(User).where(
                User.id.in_((current_owner_user_id, new_owner_user_id)), User.status == AccountStatus.ACTIVE))}
            if len(owners) != 2 or any(not u.matrix_user_id or u.matrix_user_id not in members for u in owners.values()):
                raise GroupOwnerError('GROUP_TRANSFER_TARGET_INVALID', '双方必须是有效的已加入成员')
            if matrix_owner_from_state(state) != owners[current_owner_user_id].matrix_user_id:
                raise GroupOwnerError('GROUP_OWNER_MISMATCH', '当前 Matrix 群主与业务登记不一致')
        joined = len(members)
        row = group if group is not None else self.registry.get(room_id)
        if row is None:
            raise GroupOwnerError("GROUP_NOT_REGISTERED", "群未注册")
        if row.owner_user_id != current_owner_user_id:
            raise GroupOwnerError("GROUP_OWNER_MISMATCH", "只有当前群主可以发起转让")
        if current_owner_user_id == new_owner_user_id:
            raise GroupOwnerError("GROUP_TRANSFER_TARGET_INVALID", "新群主不能是当前群主")
        if joined >= COOLDOWN_MIN_MEMBERS:
            if row.owner_since is None:
                raise GroupOwnerError("OWNER_TENURE_UNPROVEN",
                    "该群已满10人，当前群主任期尚未核实，请联系管理员凭接任证据补录；核实任满30天后可转让")
            now = self._utcnow()
            held = now - (row.owner_since if row.owner_since.tzinfo else row.owner_since.replace(tzinfo=timezone.utc))
            if held < COOLDOWN_PERIOD:
                raise GroupOwnerError("OWNER_TENURE_INSUFFICIENT", "满10人的群群主需任满30天才能转让")
        return row

    # ---------------------------------------------------------------- 请求
    def request(self, *, room_id, requester_user_id, current_owner_user_id,
                new_owner_user_id, idempotency_key) -> dict:
        if requester_user_id != current_owner_user_id:
            raise GroupOwnerError('GROUP_OWNER_MISMATCH', '仅当前群主可发起转让')
        payload = {"room_id": room_id, "current_owner": current_owner_user_id,
            "new_owner": new_owner_user_id}
        digest = sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        now = self._utcnow()
        with self._factory.begin() as session:
            # Serializes different idempotency keys for this room before any
            # external side effect. NEEDS_REVIEW deliberately retains ownership.
            group = session.get(BusinessGroup, room_id, with_for_update=True)
            if group is None:
                raise GroupOwnerError('GROUP_NOT_REGISTERED', '群未注册')
            existing = session.scalar(select(GroupTransferIntent).where(
                GroupTransferIntent.idempotency_key == idempotency_key))
            if existing is not None:
                if existing.request_digest != digest or existing.requester_user_id != requester_user_id:
                    raise AppError(code="IDEMPOTENCY_KEY_REUSED", message="幂等键已用于不同请求", status_code=409)
                return self._view(existing)
            active = session.scalar(select(GroupTransferIntent.id).where(
                GroupTransferIntent.room_id == room_id,
                GroupTransferIntent.stage != STAGE_COMPLETED,
                or_(GroupTransferIntent.stage != STAGE_FAILED,
                    GroupTransferIntent.last_error_code.is_(None),
                    GroupTransferIntent.last_error_code != SAFE_RELEASE_REASON)).limit(1))
            if active is not None:
                raise AppError(code='GROUP_TRANSFER_IN_PROGRESS', message='该群存在未完成或待核对转让', status_code=409)
            self._validate_domain(room_id=room_id, current_owner_user_id=current_owner_user_id,
                new_owner_user_id=new_owner_user_id, group=group)
            intent = GroupTransferIntent(id=str(uuid4()), room_id=room_id,
                requester_user_id=requester_user_id,
                expected_old_owner_user_id=current_owner_user_id,
                new_owner_user_id=new_owner_user_id, request_digest=digest,
                idempotency_key=idempotency_key, stage=STAGE_VALIDATED,
                attempts=0, created_at=now, updated_at=now)
            session.add(intent)
            return self._view(intent)

    # ---------------------------------------------------------------- 推进
    def advance(self, *, intent_id: str) -> dict:
        """认领（T2）→ 网络应用（事务外）→ 权威确认（T3）。可重入。"""
        claim_token = secrets.token_hex(16)
        now = self._utcnow()
        with self._factory.begin() as session:
            intent = session.get(GroupTransferIntent, intent_id, with_for_update=True)
            if intent is None:
                raise AppError(code="GROUP_TRANSFER_INTENT_NOT_FOUND", message="转让操作不存在", status_code=404)
            if intent.stage in (STAGE_COMPLETED, STAGE_NEEDS_REVIEW):
                return self._view(intent)
            # An expired network claim is an unknown external outcome, never
            # permission to submit the state event a second time.
            claimable = intent.stage == STAGE_VALIDATED
            if not claimable:
                return self._view(intent)
            intent.stage, intent.attempts = STAGE_MATRIX_PENDING, intent.attempts + 1
            intent.claim_token, intent.claim_at = claim_token, now
            intent.last_error_code = None
            intent.updated_at = now
            room_id = intent.room_id
            expected_old, new_owner = intent.expected_old_owner_user_id, intent.new_owner_user_id
            expected_old_matrix = self.registry.matrix_user_id(expected_old)
            new_owner_matrix = self.registry.matrix_user_id(new_owner)
        if not expected_old_matrix or not new_owner_matrix:
            return self._fail(intent_id, "GROUP_IDENTITY_MISSING", claim_token=claim_token, not_sent=True)
        # ---- 网络段（事务外）：以旧群主身份应用 power levels ----
        try:
            self._validate_domain(room_id=room_id, current_owner_user_id=expected_old,
                new_owner_user_id=new_owner)
            state_before = self._gateway.get_room_state(room_id)
            if matrix_owner_from_state(state_before) != expected_old_matrix:
                return self._fail(intent_id, 'GROUP_OWNER_MISMATCH', claim_token=claim_token, not_sent=True)
            content = self._next_power_levels(state_before,
                promote=new_owner_matrix, demote=expected_old_matrix)
        except GroupOwnerError as error:
            return self._fail(intent_id, error.code, claim_token=claim_token, not_sent=True)
        except Exception:
            return self._record_failure(intent_id, claim_token, error='MATRIX_AUTHORITY_UNAVAILABLE', ambiguous=False)
        try:
            self._gateway.send_room_state_as_user(expected_old_matrix, room_id,
                "m.room.power_levels", content)
        except Exception:
            return self._record_failure(intent_id, claim_token)
        # ---- 权威确认（T3）----
        applied = self._confirm_applied(room_id, new_owner_matrix=new_owner_matrix,
            old_owner_matrix=expected_old_matrix)
        if not applied:
            return self._record_failure(intent_id, claim_token, error="MATRIX_STATE_UNCONFIRMED")
        return self._mark_applied(intent_id, claim_token)

    @staticmethod
    def _power_users(state_events):
        from app.modules.groups.registry import parse_power_level_users

        return parse_power_level_users(state_events)

    @staticmethod
    def _next_power_levels(state: list, *, promote: str, demote: str) -> dict:
        content = next((deepcopy(event['content']) for event in state
            if event.get('type') == 'm.room.power_levels' and event.get('state_key', '') == ''), None)
        if not isinstance(content, dict):
            raise GroupOwnerError('GROUP_AUTHORITY_UNAVAILABLE', '缺少权威权限事件')
        users = dict(content.get('users', {}))
        users[promote] = users[demote]
        users[demote] = 0
        content['users'] = users
        return content

    def _confirm_applied(self, room_id: str, *, new_owner_matrix: str, old_owner_matrix: str) -> bool:
        try:
            state = self._gateway.get_room_state(room_id)
            members = set(self._gateway.get_room_members(room_id))
        except Exception:
            return False
        holder = matrix_owner_from_state(state)
        if holder != new_owner_matrix or new_owner_matrix not in members:
            return False
        users = self._power_users(state)
        return int(users.get(old_owner_matrix, 0)) < CREATOR_POWER

    def _record_failure(self, intent_id: str, claim_token: str, error: str = "MATRIX_APPLY_FAILED", *, ambiguous=True) -> dict:
        with self._factory.begin() as session:
            intent = session.get(GroupTransferIntent, intent_id, with_for_update=True)
            if intent is None or intent.claim_token != claim_token or intent.stage != STAGE_MATRIX_PENDING:
                return self._view(intent)  # 认领已被过期回收，不写回
            if ambiguous:
                intent.stage, intent.last_error_code = STAGE_MATRIX_PENDING, error
            elif intent.attempts >= self.max_attempts:
                intent.stage, intent.last_error_code = STAGE_NEEDS_REVIEW, error
                intent.claim_token, intent.claim_at = None, None
            else:
                intent.stage, intent.last_error_code = STAGE_VALIDATED, error
            intent.updated_at = self._utcnow()
            return self._view(intent)

    def _mark_applied(self, intent_id: str, claim_token: str) -> dict:
        with self._factory.begin() as session:
            intent = session.get(GroupTransferIntent, intent_id, with_for_update=True)
            if intent is None or intent.claim_token != claim_token or intent.stage != STAGE_MATRIX_PENDING:
                return self._view(intent)
            if intent.stage == STAGE_MATRIX_PENDING:
                intent.stage = STAGE_MATRIX_APPLIED
                intent.updated_at = self._utcnow()
            return self._view(intent)

    def _fail(self, intent_id: str, error: str, *, claim_token=None, not_sent=False) -> dict:
        with self._factory.begin() as session:
            intent = session.get(GroupTransferIntent, intent_id, with_for_update=True)
            if intent is None:
                return {}
            if intent.stage != STAGE_MATRIX_PENDING or (claim_token is not None and intent.claim_token != claim_token):
                return self._view(intent)
            intent.stage = STAGE_NEEDS_REVIEW
            intent.last_error_code = error
            if not_sent:
                # Durable proof of a completed preflight failure, never a timeout.
                intent.claim_token, intent.claim_at = None, None
            intent.updated_at = self._utcnow()
            return self._view(intent)

    # ---------------------------------------------------------------- 完成
    def complete(self, *, intent_id: str, actor_id: str = "group-transfer-coordinator") -> dict:
        """T4：条件换主（WHERE owner=预期旧群主）+ owner_since=now + COMPLETED。"""
        from app.modules.audit.models import AuditEvent

        now = self._utcnow()
        with self._factory.begin() as session:
            intent = session.get(GroupTransferIntent, intent_id, with_for_update=True)
            if intent is None:
                raise AppError(code="GROUP_TRANSFER_INTENT_NOT_FOUND", message="转让操作不存在", status_code=404)
            if intent.stage == STAGE_COMPLETED:
                return self._view(intent)
            if intent.stage != STAGE_MATRIX_APPLIED:
                raise AppError(code="GROUP_TRANSFER_NOT_CONFIRMED", message="Matrix 侧尚未确认应用", status_code=409)
            if not self._confirm_applied(intent.room_id,
                    new_owner_matrix=self.registry.matrix_user_id(intent.new_owner_user_id),
                    old_owner_matrix=self.registry.matrix_user_id(intent.expected_old_owner_user_id)):
                intent.stage, intent.last_error_code = STAGE_NEEDS_REVIEW, 'MATRIX_STATE_DRIFT'
                intent.updated_at = now
                return self._view(intent)
            updated = session.execute(
                update(BusinessGroup).where(BusinessGroup.room_id == intent.room_id,
                    BusinessGroup.owner_user_id == intent.expected_old_owner_user_id)
                .values(owner_user_id=intent.new_owner_user_id, owner_since=now,
                    tenure_source="transfer", updated_at=now))
            if updated.rowcount != 1:
                intent.stage, intent.last_error_code = STAGE_NEEDS_REVIEW, "REGISTRY_CONFLICT"
                intent.updated_at = now
                session.flush()
                return self._view(intent)
            intent.stage, intent.completed_at = STAGE_COMPLETED, now
            intent.updated_at = now
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="business_group",
                subject_id=intent.room_id, action="group.owner_transferred", result="SUCCESS",
                reason_code="GROUP_OWNER_TRANSFER", trace_id=intent.id[:32],
                after_data={"new_owner_user_id": intent.new_owner_user_id}, created_at=now))
            return self._view(intent)

    # ---------------------------------------------------------------- 恢复
    def recover_batch(self, *, limit: int = 20) -> dict:
        """worker：VALIDATED 推进；MATRIX_PENDING 认领超时先读权威状态短路。"""
        now = self._utcnow()
        with self._factory() as session:
            candidates = session.scalars(select(GroupTransferIntent.id).where(
                GroupTransferIntent.stage.in_((STAGE_VALIDATED, STAGE_MATRIX_PENDING, STAGE_MATRIX_APPLIED)))
                .order_by(GroupTransferIntent.updated_at).limit(limit)).all()
        completed = retried = review = 0
        for intent_id in candidates:
            with self._factory() as session:
                intent = session.get(GroupTransferIntent, intent_id)
                if intent is None:
                    continue
                stage = intent.stage
                room_id, new_owner = intent.room_id, intent.new_owner_user_id
                expected_old = intent.expected_old_owner_user_id
            if stage == STAGE_MATRIX_APPLIED:
                result = self.complete(intent_id=intent_id)
                completed += result['stage'] == STAGE_COMPLETED
                review += result['stage'] == STAGE_NEEDS_REVIEW
                continue
            if stage == STAGE_MATRIX_PENDING:
                claimed_recently = intent.claim_at is not None and (
                    now - (intent.claim_at if intent.claim_at.tzinfo else intent.claim_at.replace(tzinfo=timezone.utc))
                ) <= timedelta(seconds=CLAIM_TIMEOUT_SECONDS)
                if claimed_recently:
                    continue  # 其他进程正在处理
                # 崩溃恢复短路：权威状态已应用则直接推进
                new_matrix = self.registry.matrix_user_id(new_owner)
                old_matrix = self.registry.matrix_user_id(expected_old)
                try:
                    if new_matrix and old_matrix and self._confirm_applied(room_id,
                            new_owner_matrix=new_matrix, old_owner_matrix=old_matrix):
                        self._mark_applied(intent_id, intent.claim_token or "")
                        result = self.complete(intent_id=intent_id)
                        completed += result['stage'] == STAGE_COMPLETED
                        review += result['stage'] == STAGE_NEEDS_REVIEW
                        continue
                except Exception:
                    pass
                self._fail(intent_id, 'MATRIX_OUTCOME_UNKNOWN', claim_token=intent.claim_token)
                review += 1
                continue
            view = self.advance(intent_id=intent_id)
            if view.get("stage") == STAGE_MATRIX_APPLIED:
                result = self.complete(intent_id=intent_id)
                completed += result['stage'] == STAGE_COMPLETED
                review += result['stage'] == STAGE_NEEDS_REVIEW
            elif view.get("stage") in (STAGE_NEEDS_REVIEW,):
                review += 1
            elif view.get("stage") == STAGE_COMPLETED:
                completed += 1
            else:
                retried += 1
        return {"scanned": len(candidates), "completed": completed, "retried": retried, "review": review}

    # ------------------------------------------------ 待核对处置（ADR-0079）
    def intents_timeline(self, room_id: str, *, limit: int = 50) -> list[dict]:
        """房间转让意图时间线（只读；权限由 API 层校验）。"""
        with self._factory() as session:
            rows = session.scalars(select(GroupTransferIntent).where(
                GroupTransferIntent.room_id == room_id)
                .order_by(GroupTransferIntent.created_at.desc(), GroupTransferIntent.id.desc())
                .limit(min(limit, 100))).all()
            return [self._view(row) for row in rows]

    def review_intent(self, *, intent_id: str, action: str, actor_id: str) -> dict:
        """Reconcile positive authority; release only durable never-sent evidence.

        An old-owner snapshot cannot disprove an in-flight or delayed Matrix write.
        Legacy FAILED rows without the new safe-release evidence remain quarantined.
        """
        from app.modules.audit.models import AuditEvent

        if action not in ("confirm_applied", "fail_unapplied"):
            raise AppError(code="GROUP_TRANSFER_REVIEW_ACTION_INVALID", message="处置动作无效", status_code=422)
        now = self._utcnow()
        with self._factory.begin() as session:
            intent = session.get(GroupTransferIntent, intent_id, with_for_update=True)
            if intent is None:
                raise AppError(code="GROUP_TRANSFER_INTENT_NOT_FOUND", message="转让操作不存在", status_code=404)
            if action == "confirm_applied" and intent.stage == STAGE_COMPLETED:
                return self._view(intent)
            if (action == "fail_unapplied" and intent.stage == STAGE_FAILED
                    and intent.last_error_code == SAFE_RELEASE_REASON):
                return self._view(intent)
            resuming_confirmation = (action == "confirm_applied" and intent.stage == STAGE_MATRIX_APPLIED
                and intent.last_error_code == "REVIEW_CONFIRMED_APPLIED")
            if intent.stage not in (STAGE_NEEDS_REVIEW, STAGE_MATRIX_PENDING) and not resuming_confirmation:
                raise AppError(code="GROUP_TRANSFER_REVIEW_NOT_ALLOWED",
                    message="仅待核对/在途意图可复核", status_code=409)
            old_matrix = self.registry.matrix_user_id(intent.expected_old_owner_user_id)
            new_matrix = self.registry.matrix_user_id(intent.new_owner_user_id)
            if action == "confirm_applied":
                if not old_matrix or not new_matrix or not self._confirm_applied(intent.room_id,
                        new_owner_matrix=new_matrix, old_owner_matrix=old_matrix):
                    raise AppError(code="GROUP_TRANSFER_NOT_CONFIRMED",
                        message="权威状态未显示新群主，不能依据既成事实完成", status_code=409)
                intent.stage = STAGE_MATRIX_APPLIED
                # Fence all callbacks from the former network claim.
                intent.claim_token = secrets.token_hex(16)
                intent.updated_at = now
                intent.last_error_code = "REVIEW_CONFIRMED_APPLIED"
                if not resuming_confirmation:
                    session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="business_group",
                        subject_id=intent.room_id, action="group.transfer_intent_confirmed", result="SUCCESS",
                        reason_code="REVIEW_CONFIRMED_APPLIED", trace_id=intent.id[:32],
                        after_data={"intent_id": intent.id}, created_at=now))
            else:
                # Only a completed pre-send failure clears both claim markers.
                never_sent = (intent.stage == STAGE_NEEDS_REVIEW
                    and intent.attempts > 0 and intent.claim_token is None and intent.claim_at is None)
                if not never_sent:
                    raise AppError(code="GROUP_TRANSFER_UNPROVEN_UNAPPLIED",
                        message="无法排除在途权限写入，不得失败化释放", status_code=409)
                try:
                    state = self._gateway.get_room_state(intent.room_id)
                except Exception:
                    raise AppError(code="GROUP_AUTHORITY_UNAVAILABLE", message="群权限权威不可用", status_code=503) from None
                if not old_matrix or matrix_owner_from_state(state) != old_matrix:
                    raise AppError(code="GROUP_TRANSFER_UNPROVEN_UNAPPLIED",
                        message="当前权限状态不明，不得失败化释放", status_code=409)
                intent.stage, intent.last_error_code = STAGE_FAILED, SAFE_RELEASE_REASON
                intent.updated_at = now
                session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="business_group",
                    subject_id=intent.room_id, action="group.transfer_intent_failed", result="SUCCESS",
                    reason_code=SAFE_RELEASE_REASON, trace_id=intent.id[:32],
                    after_data={"intent_id": intent.id}, created_at=now))
                return self._view(intent)
        return self.complete(intent_id=intent_id, actor_id=actor_id)

    @staticmethod
    def _view(intent: GroupTransferIntent) -> dict:
        if intent is None:
            return {}
        return {"id": intent.id, "room_id": intent.room_id,
            "expected_old_owner_user_id": intent.expected_old_owner_user_id,
            "new_owner_user_id": intent.new_owner_user_id,
            "stage": intent.stage, "attempts": intent.attempts,
            "last_error_code": intent.last_error_code,
            "created_at": intent.created_at.isoformat() if intent.created_at else None}
