"""Delivery opportunities, retry ownership and bounded gateway state.

Only the external provider is replaced; requests exercise the real sanitizer,
rate limiter, thread dispatch and Getui client.
"""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from threading import Event, Lock
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

import app.main as main
import app.rate_limit as rate_limit
from app.config import BridgeSettings


def notification(room="!room:a", event="$event-1", cids=("test-cid",), scope="a" * 64, legacy=False):
    devices = [{"app_id": "com.liuhetong.mobile.getui", "pushkey": cid} for cid in cids]
    if not legacy:
        for device in devices:
            device["data"] = {"chatflow_push_v": 1, "chatflow_push_scope": scope,
                              "chatflow_push_revision": 1}
    return {"notification": {"type": "m.room.encrypted", "room_id": room,
                             "event_id": event, "content": {"body": "PRIVATE BODY"},
                             "devices": devices}}


@pytest.fixture
def clock(monkeypatch):
    now = [100.0]
    monkeypatch.setattr(rate_limit, "time", SimpleNamespace(monotonic=lambda: now[0]))
    return now


class Provider:
    def __init__(self):
        self.sent = []
        self.reply = lambda body: httpx.Response(200, json={"code": 0})
        self.lock = Lock()

    def handle(self, request):
        if request.url.path.endswith("/auth"):
            return httpx.Response(200, json={"code": 0, "data": {
                "token": "test-token", "expire_time": 9999999999999}})
        body = json.loads(request.content)
        with self.lock:
            self.sent.append(body)
        return self.reply(body)

    def app(self, interval=1500):
        return main.create_app(BridgeSettings(
            getui_app_id="test", getui_app_key="test", getui_sign_secret="test",
            rate_limit_ms=interval,
        ), http_client=httpx.Client(transport=httpx.MockTransport(self.handle)))


@pytest.fixture
def provider():
    return Provider()


def post(client, **kwargs):
    return client.post("/_matrix/push/v1/notify", json=notification(**kwargs))


def test_distinct_rooms_100ms_apart_both_reach_device_policy(provider, clock):
    client = TestClient(provider.app())
    assert post(client, room="!muted:a").status_code == 200
    clock[0] += 0.1
    assert post(client, room="!audible:b", event="$event-2").status_code == 200
    envelopes = [json.loads(body["push_message"]["transmission"]) for body in provider.sent]
    # A is muted on device. B must still reach that policy owner; the gateway
    # neither knows local mute state nor bypasses it through UPS display.
    audible_room = hashlib.sha256(("a" * 64 + "\0!audible:b").encode()).hexdigest()
    assert len(envelopes) == 2
    assert sum(payload["room_key"] == audible_room for payload in envelopes) == 1
    assert all("push_channel" not in body for body in provider.sent)


def test_new_session_scope_does_not_inherit_old_room_cooldown(provider, clock):
    client = TestClient(provider.app())
    assert post(client).status_code == 200
    clock[0] += 0.1
    assert post(client, scope="b" * 64).status_code == 200
    assert len(provider.sent) == 2


def test_successful_event_dedup_survives_room_cooldown(provider, clock):
    client = TestClient(provider.app())
    assert post(client).status_code == 200
    clock[0] += 10
    assert post(client).status_code == 200
    assert len(provider.sent) == 1


def test_same_room_new_event_gets_retry_until_it_can_be_delivered(provider, clock):
    client = TestClient(provider.app())
    assert post(client).status_code == 200
    clock[0] += 0.1
    retry = post(client, event="$event-2")
    assert retry.status_code == 503
    assert not retry.json().get("rejected")
    clock[0] += 1.5
    assert post(client, event="$event-2").status_code == 200
    assert len(provider.sent) == 2


def test_partial_retry_preserves_success_and_permanent_rejection(provider, clock):
    fail = [True]

    def reply(body):
        cid = body["audience"]["cid"][0]
        if cid == "dead":
            return httpx.Response(400, json={"code": 20103})
        if cid == "retry" and fail[0]:
            return httpx.Response(200, json={"code": 30005})
        return httpx.Response(200, json={"code": 0})

    provider.reply = reply
    client = TestClient(provider.app())
    first = post(client, cids=("ok", "dead", "retry"))
    assert first.status_code == 503
    assert first.json() == {"rejected": ["dead"]}
    fail[0] = False
    clock[0] += 10  # Synapse retry can arrive later than the 1.5s cooldown.
    second = post(client, cids=("ok", "dead", "retry"))
    assert second.status_code == 200
    assert second.json() == {"rejected": ["dead"]}
    cids = [body["audience"]["cid"][0] for body in provider.sent]
    assert cids.count("ok") == 1
    assert cids.count("dead") == 1
    assert cids.count("retry") == 2


@pytest.mark.parametrize("error", [httpx.ConnectTimeout, httpx.ReadTimeout])
def test_transport_retry_releases_event_without_sensitive_logs(provider, clock, caplog, error):
    def timeout(body):
        raise error("PRIVATE BODY test-cid")

    provider.reply = timeout
    client = TestClient(provider.app())
    response = post(client)
    assert response.status_code == 503
    assert not response.json().get("rejected")
    provider.reply = lambda body: httpx.Response(200, json={"code": 0})
    assert post(client).status_code == 200
    assert len(provider.sent) == 2
    assert "PRIVATE BODY" not in caplog.text
    assert "test-cid" not in caplog.text


def test_inflight_duplicate_is_retryable_not_acknowledged(provider, clock):
    started, release = Event(), Event()

    def delayed(body):
        started.set()
        assert release.wait(5)
        return httpx.Response(200, json={"code": 0})

    provider.reply = delayed
    client = TestClient(provider.app())
    with ThreadPoolExecutor(max_workers=1) as pool:
        first = pool.submit(post, client)
        try:
            assert started.wait(5)
            clock[0] += 10
            assert post(client).status_code == 503
        finally:
            release.set()
        assert first.result(timeout=5).status_code == 200
    assert post(client).status_code == 200
    assert len(provider.sent) == 1


def test_old_failed_event_cannot_release_newer_room_reservation(provider, clock):
    started, release = Event(), Event()
    first_event = hashlib.sha256(("a" * 64 + "\0$event-1").encode()).hexdigest()

    def reply(body):
        if json.loads(body["push_message"]["transmission"])["event_key"] == first_event:
            started.set()
            assert release.wait(5)
            raise httpx.ConnectTimeout("test timeout")
        return httpx.Response(200, json={"code": 0})

    provider.reply = reply
    client = TestClient(provider.app())
    with ThreadPoolExecutor(max_workers=1) as pool:
        first = pool.submit(post, client)
        try:
            assert started.wait(5)
            clock[0] += 1.6
            assert post(client, event="$event-2").status_code == 200
        finally:
            release.set()
        assert first.result(timeout=5).status_code == 503
    clock[0] += 0.1
    assert post(client, event="$event-3").status_code == 503
    assert len(provider.sent) == 2


def test_total_provider_concurrency_is_bounded_across_requests(provider, clock):
    started, release = Event(), Event()
    active = [0]
    guard = Lock()

    def delayed(body):
        with guard:
            active[0] += 1
            if active[0] == 4:
                started.set()
        assert release.wait(5)
        return httpx.Response(200, json={"code": 0})

    provider.reply = delayed
    client = TestClient(provider.app())
    with ThreadPoolExecutor(max_workers=4) as pool:
        pending = [pool.submit(post, client, cids=(f"cid-{i}",)) for i in range(4)]
        try:
            assert started.wait(5)
            overflow = post(client, cids=("overflow",))
            assert overflow.status_code == 503
            assert not overflow.json().get("rejected")
            assert len(provider.sent) == 4
        finally:
            release.set()
        assert all(future.result(timeout=5).status_code == 200 for future in pending)


@pytest.mark.parametrize("legacy", [False, True])
def test_state_capacity_is_retryable_and_ttl_reclaims_slots(provider, clock, monkeypatch, legacy):
    monkeypatch.setattr(rate_limit, "MAX_TRACKED_ENTRIES", 2, raising=False)
    client = TestClient(provider.app())
    assert post(client, cids=("one",), legacy=legacy).status_code == 200
    assert post(client, cids=("two",), legacy=legacy).status_code == 200
    if not legacy:
        clock[0] += 2  # Room windows expire; completed events still own their slots.
    assert post(client, cids=("three",), legacy=legacy).status_code == 503
    assert post(client, cids=("one",), legacy=legacy).status_code == 200
    assert len(provider.sent) == 2
    clock[0] += 300.1
    assert post(client, cids=("three",), legacy=legacy).status_code == 200
    assert len(provider.sent) == 3


def test_cancelled_request_keeps_running_provider_slot(provider, clock, monkeypatch):
    monkeypatch.setattr(main, "MAX_CONCURRENT_PUSHES", 1)
    started, release, finished = Event(), Event(), Event()

    def delayed(body):
        started.set()
        assert release.wait(5)
        finished.set()
        return httpx.Response(200, json={"code": 0})

    provider.reply = delayed
    application = provider.app()

    async def scenario():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=application),
                                     base_url="http://test") as client:
            first = asyncio.create_task(client.post("/_matrix/push/v1/notify", json=notification()))
            try:
                assert await asyncio.to_thread(started.wait, 5)
                first.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await first
                overflow = await client.post("/_matrix/push/v1/notify", json=notification(cids=("other",)))
                assert overflow.status_code == 503
                assert len(provider.sent) == 1
            finally:
                release.set()
                await asyncio.to_thread(finished.wait, 5)

    asyncio.run(scenario())
