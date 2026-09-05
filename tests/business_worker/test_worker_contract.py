"""审计 C02/C03：Outbox 主题契约、死信与维护任务隔离。

- C02：枚举生产者主题并断言消费者覆盖决策；未知主题不占用热队列而进入
  可审计死信；失败重试有界指数退避；超最大尝试次数进 DEAD（人工可重放）；
- C03：单个维护任务抛错不影响其他任务与消息循环；健康状态能区分
  "进程活着"与"任务持续失败"；任务按周期独立调度。
"""
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher

WORKER_APP = Path(__file__).parents[2] / "services" / "business-worker" / "app"
sys.path.insert(0, str(WORKER_APP))

from worker import Worker  # noqa: E402


def _components(handlers, maintenance=None, now=None, max_attempts=3):
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = now or datetime(2026, 9, 5, 12, 0, tzinfo=timezone.utc)
    consumer = OutboxConsumer(factory, now_factory=lambda: now)
    worker = Worker(
        consumer=consumer, handlers=handlers, worker_id="t",
        now_factory=lambda: now, maintenance_tasks=maintenance or [],
        max_attempts=max_attempts,
    )
    return engine, factory, now, worker, consumer


def test_c02_claim_batch_filters_to_handled_topics():
    """消费者只领取已注册 handler 的主题——未知主题不占用热队列。"""
    engine, factory, now, worker, consumer = _components({"identity.email": lambda m: None})
    with factory.begin() as session:
        mail_id = OutboxPublisher.enqueue(session, topic="identity.email", event_type="x", aggregate_type="t", aggregate_id="a", payload={}, now=now)
        ledger_id = OutboxPublisher.enqueue(session, topic="ledger", event_type="ledger.posted", aggregate_type="t", aggregate_id="b", payload={}, now=now)
    handled = worker.run_once(limit=10)
    assert handled == 1
    with factory() as session:
        assert session.get(OutboxEvent, mail_id).status == "PUBLISHED"
        assert session.get(OutboxEvent, ledger_id).status == "PENDING", "未声明主题不被领取"
    engine.dispose()


def test_c02_reap_undeliverable_moves_unknown_topics_to_dead_letter():
    """无消费者主题 → DEAD（可审计、有人工重放路径）；宽限窗口内不动。"""
    engine, factory, now, worker, consumer = _components({"identity.email": lambda m: None})
    with factory.begin() as session:
        fresh_id = OutboxPublisher.enqueue(session, topic="ledger", event_type="ledger.posted", aggregate_type="t", aggregate_id="fresh", payload={}, now=now)
        stale_id = OutboxPublisher.enqueue(session, topic="ledger", event_type="ledger.posted", aggregate_type="t", aggregate_id="stale", payload={}, now=now - timedelta(hours=2))
    # 宽限窗口内（新鲜事件）不收割；超龄事件进死信。
    assert consumer.reap_undeliverable(worker.handled_topics, max_age=timedelta(minutes=10)) == 1
    with factory() as session:
        assert session.get(OutboxEvent, fresh_id).status == "PENDING", "宽限窗口内的部署错位留给消费者上线"
        row = session.get(OutboxEvent, stale_id)
        assert row.status == "DEAD"
        assert "no registered consumer" in (row.last_error or "")
        # 人工重放路径：重置 PENDING 即可。
        row.status = "PENDING"
    engine.dispose()


def test_c02_producer_topics_are_covered_or_dead_lettered():
    """生产者→主题→消费者契约表：当前 worker 注册 identity.*；其余主题
    由死信收割兜底（有界积压 + 告警），不静默丢失。"""
    producer_topics = {
        "admin", "identity.email", "identity.matrix", "identity.profile",
        "ledger", "moments", "moments.events", "notification", "friendship.events",
    }
    engine, factory, now, worker, _ = _components({
        "identity.email": lambda m: None,
        "identity.matrix": lambda m: None,
        "identity.profile": lambda m: None,
    })
    assert set(worker.handled_topics) == {"identity.email", "identity.matrix", "identity.profile"}
    # 每个生产主题要么被消费、要么被死信收割处理（二者必有其一）。
    for topic in producer_topics:
        with factory.begin() as session:
            event_id = OutboxPublisher.enqueue(session, topic=topic, event_type="t", aggregate_type="t", aggregate_id=topic, payload={}, now=now - timedelta(hours=1))
        worker.run_once(limit=10)
        worker._reap_undeliverable()
        with factory() as session:
            status = session.get(OutboxEvent, event_id).status
        if topic.startswith("identity."):
            assert status == "PUBLISHED", f"{topic} 应被消费"
        else:
            assert status == "DEAD", f"{topic} 无消费者应进死信（可审计+可重放）"
    engine.dispose()


def test_c02_retry_backoff_is_bounded_and_dead_letters_after_max_attempts():
    """失败重试有界指数退避；超过最大尝试次数 → DEAD（不再占用队列）。"""
    calls = []
    clock = {"now": datetime(2026, 9, 5, 12, 0, tzinfo=timezone.utc)}
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    consumer = OutboxConsumer(factory, now_factory=lambda: clock["now"])
    worker = Worker(
        consumer=consumer,
        handlers={"identity.email": lambda m: calls.append(m) or (_ for _ in ()).throw(RuntimeError("always fails"))},
        worker_id="t", now_factory=lambda: clock["now"], max_attempts=3,
    )
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(session, topic="identity.email", event_type="x", aggregate_type="t", aggregate_id="a", payload={}, now=clock["now"])
    # 三次失败（每次推进时钟越过退避窗口）；之后不再重试。
    worker.run_once(limit=10)
    clock["now"] += timedelta(hours=2)
    worker.run_once(limit=10)
    clock["now"] += timedelta(hours=2)
    worker.run_once(limit=10)
    worker.run_once(limit=10)
    with factory() as session:
        row = session.get(OutboxEvent, event_id)
        assert row.status == "DEAD", "超过最大尝试次数进入死信"
        assert row.attempt_count == 3
        assert "always fails" in row.last_error
    engine.dispose()


def test_c03_maintenance_failure_does_not_break_loop_or_other_tasks():
    """钱包维护抛错 → 其他维护任务仍执行、消息仍被领取。"""
    calls = []
    def broken_wallet():
        raise RuntimeError("wallet maintenance down")
    def healthy_redpacket():
        calls.append("redpacket")
    engine, factory, now, worker, _ = _components(
        {"identity.email": lambda m: calls.append("message")},
        maintenance=[broken_wallet, healthy_redpacket],
    )
    with factory.begin() as session:
        OutboxPublisher.enqueue(session, topic="identity.email", event_type="x", aggregate_type="t", aggregate_id="a", payload={}, now=now)
    assert worker.run_once(limit=10) == 1, "维护失败后消息循环继续"
    assert calls == ["redpacket", "message"], "其他维护任务与消息处理不受影响"
    health = {entry["name"]: entry for entry in worker.maintenance_status()}
    wallet = next(entry for entry in worker.maintenance_status() if entry["name"] == "broken_wallet")
    assert wallet["consecutive_failures"] == 1
    assert "wallet maintenance down" in wallet["last_error"], "健康状态可区分任务持续失败"
    engine.dispose()


def test_c03_maintenance_scheduling_and_recovery():
    """维护任务按周期独立调度；恢复成功后清除失败计数。"""
    from worker import Worker as W
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = {"now": datetime(2026, 9, 5, 12, 0, tzinfo=timezone.utc)}
    runs = []
    state = {"fail": True}
    def task():
        runs.append(clock["now"])
        if state["fail"]:
            raise RuntimeError("boom")
    worker = W(consumer=OutboxConsumer(factory, now_factory=lambda: clock["now"]),
               handlers={}, worker_id="t", now_factory=lambda: clock["now"],
               maintenance_tasks=[task], maintenance_interval=timedelta(seconds=30))
    worker.run_once()   # 失败
    worker.run_once()   # 未到周期 → 跳过
    assert len(runs) == 1, "周期内不重复执行"
    clock["now"] += timedelta(seconds=31)
    worker.run_once()   # 到期执行（仍失败）
    assert len(runs) == 2
    state["fail"] = False
    clock["now"] += timedelta(seconds=31)
    worker.run_once()
    status = worker.maintenance_status()[0]
    assert status["consecutive_failures"] == 0 and status["last_error"] is None
    assert status["last_success"] is not None
    engine.dispose()
