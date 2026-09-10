"""Bounded acquisition only: no stale cut can leave this helper successfully."""

from app.integrations.tron import diagnostics as diag
from app.integrations.tron.funding_source import (
    FundingSourceError,
    FundingSourcePending,
    ReserveCutSample,
)


def read_fresh_cut(monitor, expected, state, valid_cut):
    clock = monitor.resample_monotonic
    started = clock()
    polls = 0
    sample = monitor.source.read_reserve_sample(timeout_seconds=1.0)

    def reject(code):
        if "deadline" in state:
            diag.emit(
                "WARNING",
                "reserve_cut_expired_wait",
                component="manual_monitor",
                status="REJECTED",
                reason_code=code,
                waited_ms=int((clock() - started) * 1000),
                poll_count=polls,
            )
        return {"result": monitor._failed_source(code)}

    def valid(sample):
        return (
            isinstance(sample, ReserveCutSample)
            and type(sample.age_expired_only) is bool
            and valid_cut(sample.cut, monitor.source.source_identity)
        )

    if not valid(sample):
        return reject("MANUAL_SOURCE_INVALID")
    cut = sample.cut
    now_ms = int(monitor.clock().timestamp() * 1000)
    if cut.healthy and cut.heartbeat_ms <= now_ms <= cut.fresh_until_ms:
        return {"cut": cut, "expected": expected}
    if (
        not sample.age_expired_only
        or now_ms <= cut.fresh_until_ms
        or cut.heartbeat_ms > now_ms
    ):
        return reject("MANUAL_SOURCE_UNHEALTHY")
    remaining = min(
        monitor.stale_resample_budget_seconds,
        (cut.fresh_until_ms + monitor.stale_resample_budget_seconds * 1000 - now_ms)
        / 1000,
    )
    if remaining <= 0:
        return reject("MANUAL_SOURCE_UNHEALTHY")
    state.setdefault("deadline", started + remaining)
    state.setdefault("observation_id", cut.observation_id)
    deadline = state["deadline"]
    if clock() >= deadline:
        return reject("MANUAL_SOURCE_UNHEALTHY")
    prepared = monitor._begin_source_wait(expected, cut)
    if "result" in prepared:
        return prepared
    expected = prepared["expected"]
    polls = 0
    diag.emit(
        "INFO",
        "reserve_cut_expired_wait",
        component="manual_monitor",
        status="STARTED",
        observation_id=cut.observation_id,
        budget_ms=int(remaining * 1000),
    )
    while clock() < deadline:
        monitor.resample_sleep(min(1.0, deadline - clock()))
        available = deadline - clock()
        if available <= 0:
            break
        try:
            sample = monitor.source.read_reserve_sample(
                timeout_seconds=min(1.0, available)
            )
        except FundingSourcePending:
            return reject("MANUAL_SOURCE_UNHEALTHY")
        except FundingSourceError:
            if clock() >= deadline:
                break
            return reject("MANUAL_SOURCE_UNAVAILABLE")
        polls += 1
        if clock() >= deadline:
            break
        if not valid(sample):
            return reject("MANUAL_SOURCE_INVALID")
        candidate = sample.cut
        now_ms = int(monitor.clock().timestamp() * 1000)
        if candidate.observation_id < cut.observation_id:
            return reject("MANUAL_SOURCE_INVALID")
        fresh = (
            candidate.healthy
            and candidate.heartbeat_ms <= now_ms <= candidate.fresh_until_ms
        )
        if fresh and candidate.observation_id > max(
            state["observation_id"], cut.observation_id
        ):
            available = deadline - clock()
            if available <= 0:
                break
            try:
                second = monitor.source.read_reserve_sample(
                    timeout_seconds=min(1.0, available)
                )
            except FundingSourcePending:
                return reject("MANUAL_SOURCE_UNHEALTHY")
            except FundingSourceError:
                if clock() >= deadline:
                    break
                return reject("MANUAL_SOURCE_UNAVAILABLE")
            if clock() >= deadline:
                break
            if not valid(second):
                return reject("MANUAL_SOURCE_INVALID")
            confirmation_ms = int(monitor.clock().timestamp() * 1000)
            if not second.cut.healthy or not (
                second.cut.heartbeat_ms <= confirmation_ms <= second.cut.fresh_until_ms
            ):
                return reject("MANUAL_SOURCE_UNHEALTHY")
            if second.cut != candidate:
                return {
                    "result": dict(
                        complete=False, status="RETRY", codes=["MANUAL_SOURCE_CHANGED"]
                    )
                }
            diag.emit(
                "INFO",
                "reserve_cut_expired_wait",
                component="manual_monitor",
                status="RECOVERED",
                observation_id=candidate.observation_id,
                previous_observation_id=state["observation_id"],
                waited_ms=int((clock() - started) * 1000),
                poll_count=polls,
            )
            return {"cut": candidate, "second": second.cut, "expected": expected}
        if not fresh and (
            not sample.age_expired_only or candidate.heartbeat_ms > now_ms
        ):
            return reject("MANUAL_SOURCE_UNHEALTHY")
    diag.emit(
        "WARNING",
        "reserve_cut_expired_wait",
        component="manual_monitor",
        status="TIMED_OUT",
        observation_id=cut.observation_id,
        waited_ms=int((clock() - started) * 1000),
        poll_count=polls,
    )
    return reject("MANUAL_SOURCE_UNHEALTHY")
