from pathlib import Path
import sys
import asyncio
import httpx
import pytest


@pytest.fixture
def env(tmp_path):
    sys.path.insert(0, str(Path(__file__).parents[1]))
    from gateway import create_app, Settings

    class Matrix:
        sessions = {
            "a": ("@a:test", "A"),
            "b": ("@b:test", "B"),
            "b2": ("@b:test", "B2"),
            "b-new": ("@b:test", "B"),
        }
        members = {"@a:test", "@b:test"}
        encrypted = True
        blocked = set()

        def identity(self, token):
            from fastapi import HTTPException

            if token not in self.sessions:
                raise HTTPException(401, "invalid_session")
            return self.sessions[token]

        def room(self, token, room_id):
            return self.encrypted, self.members

        def eligible(self, user, device):
            return (user, device) not in self.blocked

    class Push:
        sent = []
        status = 200

        def send(self, token, payload, voip, expires):
            self.sent.append((token, payload, voip, expires))
            return self.status

    matrix, push, clock = Matrix(), Push(), [1000]
    push.sent = []
    app = create_app(
        Settings(database=str(tmp_path / "routes.sqlite"), matrix_server_name="test"),
        matrix,
        push,
        lambda: clock[0],
    )

    def req(method, path, token="a", body=None):
        async def execute():
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="https://gateway.test"
            ) as client:
                return await client.request(
                    method,
                    path,
                    headers={"Authorization": "Bearer " + token},
                    json=body,
                )

        return asyncio.run(execute())

    def register(token="b", digit="b"):
        return req(
            "PUT",
            "/v1/devices/ios",
            token,
            {"voip_token": digit * 64, "apns_token": digit * 64},
        )

    return req, register, matrix, push, clock, app


CALL = {"room_id": "!r:test", "call_id": "c1", "recipient": "@b:test", "video": False}
REF = {"room_id": "!r:test", "call_id": "c1"}


def test_auth_and_strict_input(env):
    req, reg, matrix, push, clock, app = env
    assert reg("bad").status_code == 401
    matrix.sessions["missing"] = ("@a:test", "")
    assert reg("missing").status_code == 401
    assert req("POST", "/v1/calls", body={**CALL, "sdp": "private"}).status_code == 422
    assert (
        "private" not in req("POST", "/v1/calls", body={**CALL, "sdp": "private"}).text
    )


@pytest.mark.parametrize(
    "encrypted,members",
    [
        (False, {"@a:test", "@b:test"}),
        (True, {"@a:test", "@b:test", "@c:test"}),
        (True, {"@b:test"}),
    ],
)
def test_reject_unsafe_rooms(env, encrypted, members):
    req, reg, matrix, push, *_ = env
    reg()
    matrix.encrypted = encrypted
    matrix.members = members
    assert req("POST", "/v1/calls", body=CALL).status_code == 403
    assert push.sent == []


def test_dedup_privacy_and_terminal_replay(env):
    req, reg, matrix, push, clock, app = env
    assert reg().status_code == 200
    first = req("POST", "/v1/calls", body=CALL)
    assert first.status_code == 200
    assert req("POST", "/v1/calls", body=CALL).status_code == 200
    assert len(push.sent) == 1
    assert set(push.sent[0][1]) == {"aps", "room_id", "call_id", "video", "expires_at"}
    assert push.sent[0][2:] == (True, 1030)
    assert "b" * 64 not in first.text
    assert req("POST", "/v1/calls/end", body=REF).json()["state"] == "ended"
    assert not push.sent[-1][2]
    assert req("POST", "/v1/calls", body=CALL).status_code == 409
    clock[0] += 31
    assert req("POST", "/v1/calls", body=CALL).status_code == 409


def test_first_answer_wins(env):
    req, reg, matrix, push, *_ = env
    reg()
    reg("b2", "c")
    req("POST", "/v1/calls", body=CALL)
    assert req("POST", "/v1/calls/answer", "b", REF).status_code == 200
    assert req("POST", "/v1/calls/answer", "b2", REF).status_code == 409
    assert req("POST", "/v1/calls/answer", "b", REF).status_code == 200
    cancels = [p for p in push.sent if not p[2]]
    assert len(cancels) == 1 and cancels[0][0] == "c" * 64


def test_expiry_unregister_rebinding_and_revocation(env):
    req, reg, matrix, push, clock, app = env
    reg()
    assert reg("a").status_code == 409
    assert (
        req(
            "GET", "/v1/calls/status?room_id=!r:test&call_id=unknown", "b-new"
        ).status_code
        == 404
    )
    assert req("POST", "/v1/calls", body=CALL).status_code == 409
    reg("b-new")
    assert req("POST", "/v1/calls", body={**CALL, "call_id": "c2"}).status_code == 200
    clock[0] += 31
    assert (
        req("POST", "/v1/calls/answer", "b-new", {**REF, "call_id": "c2"}).status_code
        == 409
    )
    del matrix.sessions["b-new"]
    assert req("DELETE", "/v1/devices/ios", "b-new").status_code == 401


def test_apns_rejection_and_failure_safe(env):
    req, reg, matrix, push, *_ = env
    reg()
    push.status = 410
    assert req("POST", "/v1/calls", body=CALL).status_code == 502
    push.status = 200
    assert req("POST", "/v1/calls", body={**CALL, "call_id": "c2"}).status_code == 409


def test_call_collision_and_rate_limit(env):
    req, reg, matrix, push, *_ = env
    reg()
    reg("a", "d")
    assert req("POST", "/v1/calls", body=CALL).status_code == 200
    assert (
        req("POST", "/v1/calls", "b", {**CALL, "recipient": "@a:test"}).status_code
        == 409
    )
    statuses = [
        req("POST", "/v1/calls", body={**CALL, "call_id": f"c{i}"}).status_code
        for i in range(2, 15)
    ]
    assert 429 in statuses


def test_invalid_status_query_is_safe_client_error(env):
    req, *_ = env
    assert req("GET", "/v1/calls/status?room_id=bad&call_id=c").status_code == 422


def test_end_duplicate_does_not_resend(env):
    req, reg, matrix, push, *_ = env
    reg()
    req("POST", "/v1/calls", body=CALL)
    req("POST", "/v1/calls/end", body=REF)
    req("POST", "/v1/calls/end", body=REF)
    assert len(push.sent) == 2


def test_revoked_recipient_device_not_pushed(env):
    req, reg, matrix, push, *_ = env
    reg()
    matrix.blocked = {("@b:test", "B")}
    assert req("POST", "/v1/calls", body=CALL).status_code == 409
    assert push.sent == []


def test_body_limits_and_no_token_persistence(env):
    req, reg, matrix, push, clock, app = env
    assert req("POST", "/v1/calls", body={**CALL, "sdp": "z" * 5000}).status_code == 413
    matrix.sessions["SECRET_BEARER_NEVER_PERSISTED"] = ("@b:test", "B")
    reg("SECRET_BEARER_NEVER_PERSISTED")
    assert b"SECRET_BEARER_NEVER_PERSISTED" not in Path(app.state.database).read_bytes()


def test_concurrent_call_and_answer_claims(env):
    from concurrent.futures import ThreadPoolExecutor

    req, reg, matrix, push, *_ = env
    reg()
    reg("b2", "c")
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(
            pool.map(lambda _: req("POST", "/v1/calls", body=CALL), range(6))
        )
    assert all(r.status_code == 200 for r in results)
    assert len(push.sent) == 2
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(
            pool.map(lambda t: req("POST", "/v1/calls/answer", t, REF), ["b", "b2"])
        )
    assert sorted(r.status_code for r in results) == [200, 409]


def test_expired_background_token_preserves_voip_route(env):
    req, reg, matrix, push, *_ = env
    reg()
    req("POST", "/v1/calls", body=CALL)
    push.status = 410
    req("POST", "/v1/calls/end", body=REF)
    push.status = 200
    assert req("POST", "/v1/calls", body={**CALL, "call_id": "c2"}).status_code == 200


def test_observed_revoked_session_removes_route(env):
    req, reg, matrix, push, *_ = env
    reg()
    del matrix.sessions["b"]
    assert req("DELETE", "/v1/devices/ios", "b").status_code == 401
    assert req("POST", "/v1/calls", body=CALL).status_code == 409
    assert push.sent == []


def test_restart_preserves_dedup_and_status(env):
    from gateway import create_app, Settings

    req, reg, matrix, push, clock, app = env
    reg()
    req("POST", "/v1/calls", body=CALL)
    reopened = create_app(
        Settings(database=app.state.database, matrix_server_name="test"),
        matrix,
        push,
        lambda: clock[0],
    )

    async def check():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=reopened), base_url="https://gateway.test"
        ) as client:
            result = await client.post(
                "/v1/calls", json=CALL, headers={"Authorization": "Bearer a"}
            )
            assert result.status_code == 200
            assert result.json()["expires_at"] == 1030

    asyncio.run(check())
    assert len(push.sent) == 1


def test_cleanup_is_bounded_and_target_status_still_expires(env):
    import sqlite3

    req, reg, matrix, push, clock, app = env
    with sqlite3.connect(app.state.database) as db:
        db.executemany(
            "INSERT INTO calls VALUES(?,?,?,?,?,?,?,?,?)",
            [
                (
                    "!r:test",
                    f"old{i}",
                    "@a:test",
                    "@b:test",
                    0,
                    900,
                    "ringing",
                    None,
                    850,
                )
                for i in range(1500)
            ],
        )
    assert req("GET", "/healthz").status_code == 200
    with sqlite3.connect(app.state.database) as db:
        assert (
            db.execute("SELECT COUNT(*) FROM calls WHERE state='expired'").fetchone()[0]
            == 500
        )
    response = req("GET", "/v1/calls/status?room_id=!r:test&call_id=old1499")
    assert response.json()["state"] == "expired"
