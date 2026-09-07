"""Metadata-only, single-process iOS call wake gateway. Never log request bodies."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sqlite3
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote, urlparse

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from fastapi import (
    BackgroundTasks,
    Depends,
    FastAPI,
    Header,
    HTTPException,
    Query,
    Response,
)
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StrictBool


@dataclass
class Settings:
    database: str = "/data/routes.sqlite"
    matrix_url: str = "https://matrix.liuhetong888.com"
    matrix_server_name: str = "liuhetong888.com"
    matrix_admin_token: str = ""
    matrix_admin_url: str = "http://synapse:8008"
    apns_key_path: str = "/run/secrets/apns.p8"
    apns_team_id: str = ""
    apns_key_id: str = ""
    apns_sandbox: bool = False
    bundle_id: str = "com.liuhetong.liuhetongMobile"


class StrictBody(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class Device(StrictBody):
    registration_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    voip_token: str = Field(pattern=r"^[0-9a-fA-F]{64,200}$")
    apns_token: str | None = Field(default=None, pattern=r"^[0-9a-fA-F]{64,200}$")


class Reference(StrictBody):
    room_id: str = Field(min_length=3, max_length=255, pattern=r"^![^\s/]+:[^\s/]+$")
    call_id: str = Field(
        min_length=1, max_length=255, pattern=r"^[A-Za-z0-9._~+\-/=]+$"
    )


class Call(Reference):
    recipient: str = Field(min_length=3, max_length=255, pattern=r"^@[^\s/]+:[^\s/]+$")
    video: StrictBool


class Result(BaseModel):
    state: str
    expires_at: int | None = None


class Matrix:
    def __init__(self, settings):
        self.settings = settings
        parsed = urlparse(settings.matrix_url)
        if (
            parsed.scheme != "https"
            or parsed.username
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("Matrix URL must be a fixed HTTPS origin")
        # The trusted existing Docker network is the sole allowed cleartext
        # admin origin. Never forward this credential through public nginx,
        # redirects, environment proxies, arbitrary hostnames, paths or ports.
        if settings.matrix_admin_url.rstrip("/") != "http://synapse:8008":
            raise ValueError(
                "Matrix admin URL must be the fixed private Synapse origin"
            )
        self.client = httpx.Client(
            base_url=settings.matrix_url.rstrip("/"),
            timeout=8,
            follow_redirects=False,
            trust_env=False,
        )
        self.admin_client = httpx.Client(
            base_url="http://synapse:8008",
            timeout=8,
            follow_redirects=False,
            trust_env=False,
        )

    def get(self, path, token, auth=False, admin=False):
        try:
            client = self.admin_client if admin else self.client
            response = client.get(path, headers={"Authorization": "Bearer " + token})
            if response.status_code in (401, 403) and auth:
                raise HTTPException(401, "invalid_session")
            if response.status_code == 404:
                return None
            if response.status_code != 200:
                raise HTTPException(503, "matrix_unavailable")
            body = response.json()
            if not isinstance(body, dict):
                raise HTTPException(503, "matrix_unavailable")
            return body
        except (httpx.HTTPError, ValueError):
            raise HTTPException(503, "matrix_unavailable") from None

    def identity(self, token):
        body = self.get("/_matrix/client/v3/account/whoami", token, True) or {}
        if body.get("is_guest"):
            raise HTTPException(401, "invalid_session")
        return body.get("user_id"), body.get("device_id")

    def room(self, token, room_id):
        prefix = "/_matrix/client/v3/rooms/" + quote(room_id, safe="")
        encryption = self.get(prefix + "/state/m.room.encryption", token) or {}
        members = self.get(prefix + "/joined_members", token) or {}
        return encryption.get("algorithm") == "m.megolm.v1.aes-sha2", set(
            members.get("joined", {})
        )

    def eligible(self, user, device):
        token = self.settings.matrix_admin_token
        if not token:
            raise HTTPException(503, "device_verification_unavailable")
        user_path = quote(user, safe="")
        account = self.get("/_synapse/admin/v2/users/" + user_path, token, admin=True)
        if (
            not account
            or account.get("deactivated")
            or account.get("locked")
            or account.get("suspended")
        ):
            return False
        result = self.get(
            "/_synapse/admin/v2/users/"
            + user_path
            + "/devices/"
            + quote(device, safe=""),
            token,
            admin=True,
        )
        return bool(result and result.get("device_id") == device)


class APNs:
    def __init__(self, settings):
        self.settings = settings
        self.key = serialization.load_pem_private_key(
            Path(settings.apns_key_path).read_bytes(), password=None
        )
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(
            self.key.curve, ec.SECP256R1
        ):
            raise ValueError("APNs requires a P-256 signing key")
        host = (
            "https://api.sandbox.push.apple.com"
            if settings.apns_sandbox
            else "https://api.push.apple.com"
        )
        self.client = httpx.Client(
            base_url=host,
            http2=True,
            timeout=8,
            follow_redirects=False,
            trust_env=False,
        )
        self.jwt = ""
        self.issued = 0

    def bearer(self):
        now = int(time.time())
        if now - self.issued < 1200 and self.jwt:
            return self.jwt

        def enc(value):
            return base64.urlsafe_b64encode(value).rstrip(b"=").decode()

        header = enc(
            json.dumps(
                {"alg": "ES256", "kid": self.settings.apns_key_id},
                separators=(",", ":"),
            ).encode()
        )
        body = enc(
            json.dumps(
                {"iss": self.settings.apns_team_id, "iat": now}, separators=(",", ":")
            ).encode()
        )
        signing = (header + "." + body).encode()
        r, s = decode_dss_signature(self.key.sign(signing, ec.ECDSA(hashes.SHA256())))
        self.jwt = (
            signing.decode() + "." + enc(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        )
        self.issued = now
        return self.jwt

    def send(self, token, payload, voip, expires):
        try:
            response = self.client.post(
                "/3/device/" + token,
                json=payload,
                headers={
                    "authorization": "bearer " + self.bearer(),
                    "apns-topic": self.settings.bundle_id + (".voip" if voip else ""),
                    "apns-push-type": "voip" if voip else "background",
                    "apns-priority": "10" if voip else "5",
                    "apns-expiration": str(expires),
                },
            )
            if response.status_code == 400:
                try:
                    if response.json().get("reason") in (
                        "BadDeviceToken",
                        "DeviceTokenNotForTopic",
                    ):
                        return 410
                except ValueError:
                    pass
            return response.status_code
        except httpx.HTTPError:
            return 503


class BodyLimit:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        data = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            data.extend(message.get("body", b""))
            if len(data) > 4096:
                return await JSONResponse({"detail": "request_too_large"}, 413)(
                    scope, receive, send
                )
            if not message.get("more_body"):
                break
        sent = False

        async def bounded_receive():
            nonlocal sent
            if sent:
                return await receive()
            sent = True
            return {"type": "http.request", "body": bytes(data), "more_body": False}

        await self.app(scope, bounded_receive, send)


def create_app(settings=None, matrix=None, push=None, clock=time.time):
    settings = settings or Settings()
    matrix = matrix or Matrix(settings)
    push = push or APNs(settings)
    directory = Path(settings.database).parent
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name != "nt":
        os.chmod(directory, 0o700)
    db = sqlite3.connect(
        settings.database, check_same_thread=False, isolation_level=None
    )
    if os.name != "nt":
        os.chmod(settings.database, 0o600)
    db.row_factory = sqlite3.Row
    db.executescript("""
        PRAGMA journal_mode=WAL;
        PRAGMA secure_delete=ON;
        CREATE TABLE IF NOT EXISTS devices(user TEXT, device TEXT, session TEXT, voip TEXT UNIQUE, apns TEXT UNIQUE, updated INTEGER, PRIMARY KEY(user,device));
        CREATE TABLE IF NOT EXISTS calls(room TEXT, call TEXT, caller TEXT, recipient TEXT, video INTEGER, expires INTEGER, state TEXT, answer_device TEXT, created INTEGER, PRIMARY KEY(room,call));
        CREATE TABLE IF NOT EXISTS deliveries(room TEXT, call TEXT, user TEXT, device TEXT, session TEXT, PRIMARY KEY(room,call,user,device));
        CREATE TABLE IF NOT EXISTS rates(subject TEXT, bucket INTEGER, amount INTEGER, PRIMARY KEY(subject,bucket));
        CREATE TABLE IF NOT EXISTS retired_owners(user TEXT, device TEXT, registration_id TEXT, expires INTEGER, PRIMARY KEY(user,device,registration_id));
        CREATE INDEX IF NOT EXISTS call_expiry ON calls(created);
        CREATE INDEX IF NOT EXISTS call_ringing_expiry ON calls(state,expires);
        CREATE INDEX IF NOT EXISTS device_expiry ON devices(updated);
        CREATE INDEX IF NOT EXISTS rate_expiry ON rates(bucket);
        CREATE INDEX IF NOT EXISTS retired_owner_expiry ON retired_owners(expires);
    """)
    # Expand-only routing metadata migration; no business or Matrix tables.
    for table in ("devices", "deliveries"):
        columns = {row[1] for row in db.execute("PRAGMA table_info(" + table + ")")}
        if "registration_id" not in columns:
            db.execute(
                "ALTER TABLE "
                + table
                + " ADD COLUMN registration_id TEXT NOT NULL DEFAULT ''"
            )
    lock = threading.RLock()

    @contextmanager
    def transaction():
        with lock:
            db.execute("BEGIN IMMEDIATE")
            try:
                yield
                db.execute("COMMIT")
            except BaseException:
                db.execute("ROLLBACK")
                raise

    def cleanup(now):
        db.execute(
            "DELETE FROM retired_owners WHERE rowid IN (SELECT rowid FROM retired_owners WHERE expires<=? LIMIT 500)",
            (now,),
        )
        db.execute(
            "UPDATE calls SET state='expired' WHERE rowid IN (SELECT rowid FROM calls WHERE state IN ('ringing','sending','delivery_unknown') AND expires<=? LIMIT 500)",
            (now,),
        )
        db.execute(
            "DELETE FROM deliveries WHERE (room,call) IN (SELECT room,call FROM calls WHERE created<? LIMIT 500)",
            (now - 86400,),
        )
        db.execute(
            "DELETE FROM calls WHERE rowid IN (SELECT rowid FROM calls WHERE created<? LIMIT 500)",
            (now - 86400,),
        )
        db.execute(
            "DELETE FROM rates WHERE rowid IN (SELECT rowid FROM rates WHERE bucket<? LIMIT 500)",
            (now // 60 - 2,),
        )
        db.execute(
            "DELETE FROM devices WHERE rowid IN (SELECT rowid FROM devices WHERE updated<? LIMIT 500)",
            (now - 7 * 86400,),
        )

    app = FastAPI(
        title="iOS call wake gateway", version="1.0.0", docs_url=None, redoc_url=None
    )
    app.state.database = settings.database
    app.state.cancellation_failures = 0
    app.add_middleware(BodyLimit)

    @app.exception_handler(RequestValidationError)
    async def invalid_body(request, exc):
        return JSONResponse({"detail": "invalid_request"}, 422)

    def identity(authorization: str = Header(default="")):
        if not authorization.startswith("Bearer ") or len(authorization) > 8192:
            raise HTTPException(401, "invalid_session")
        token = authorization[7:]
        fingerprint = hashlib.sha256(token.encode()).hexdigest()
        try:
            user, device = matrix.identity(token)
        except HTTPException as exc:
            if exc.status_code == 401:
                with transaction():
                    db.execute("DELETE FROM devices WHERE session=?", (fingerprint,))
            raise
        if (
            not isinstance(user, str)
            or not user.startswith("@")
            or not isinstance(device, str)
            or not device
            or len(device) > 255
            or len(user) > 255
            or not user.endswith(":" + settings.matrix_server_name)
        ):
            raise HTTPException(401, "invalid_session")
        now = int(clock())
        with transaction():
            cleanup(now)
            # Distinct still-valid bearer tokens cannot be ordered by whoami.
            # Only explicit registration replaces a route's session binding;
            # an old valid request must never delete a newer owner's route.
            bucket = now // 60
            db.execute(
                "INSERT INTO rates VALUES(?,?,1) ON CONFLICT(subject,bucket) DO UPDATE SET amount=amount+1",
                ("request:" + user, bucket),
            )
            amount = db.execute(
                "SELECT amount FROM rates WHERE subject=? AND bucket=?",
                ("request:" + user, bucket),
            ).fetchone()[0]
        if amount > 120:
            raise HTTPException(429, "rate_limited")
        return user, device, fingerprint, token

    @app.get("/healthz")
    def health():
        with transaction():
            cleanup(int(clock()))
        return {"status": "ok"}

    @app.put("/v1/devices/ios", response_model=Result)
    def register(body: Device, auth=Depends(identity)):
        user, device, fingerprint, _ = auth
        voip, apns = (
            body.voip_token.lower(),
            body.apns_token.lower() if body.apns_token else None,
        )
        with transaction():
            retired = db.execute(
                "SELECT 1 FROM retired_owners WHERE user=? AND device=? AND registration_id=? AND expires>?",
                (user, device, body.registration_id, int(clock())),
            ).fetchone()
            if retired:
                raise HTTPException(409, "registration_retired")
            conflict = db.execute(
                "SELECT user,device FROM devices WHERE voip=? OR apns=?", (voip, apns)
            ).fetchall()
            if any((r["user"], r["device"]) != (user, device) for r in conflict):
                raise HTTPException(409, "route_already_bound")
            db.execute(
                "INSERT INTO devices VALUES(?,?,?,?,?,?,?) ON CONFLICT(user,device) DO UPDATE SET session=excluded.session,voip=excluded.voip,apns=excluded.apns,updated=excluded.updated,registration_id=excluded.registration_id",
                (
                    user,
                    device,
                    fingerprint,
                    voip,
                    apns,
                    int(clock()),
                    body.registration_id,
                ),
            )
        return {"state": "registered"}

    @app.delete(
        "/v1/devices/ios",
        response_model=Result,
        responses={
            204: {"description": "No matching active route; registration owner retired"}
        },
    )
    def unregister(
        registration_id: str = Header(
            alias="X-Registration-ID", pattern=r"^[0-9a-f]{32}$"
        ),
        auth=Depends(identity),
    ):
        with transaction():
            now = int(clock())
            existing = db.execute(
                "SELECT 1 FROM retired_owners WHERE user=? AND device=? AND registration_id=?",
                (*auth[:2], registration_id),
            ).fetchone()
            if not existing:
                device_count = db.execute(
                    "SELECT COUNT(*) FROM retired_owners WHERE user=? AND device=? AND expires>?",
                    (*auth[:2], now),
                ).fetchone()[0]
                total_count = db.execute(
                    "SELECT COUNT(*) FROM retired_owners WHERE expires>?", (now,)
                ).fetchone()[0]
                if device_count >= 128 or total_count >= 100000:
                    raise HTTPException(429, "registration_lifecycle_limited")
            # An HTTP timeout does not roll back an already dispatched PUT.
            # Retire even absent/mismatched owners before returning a no-op:
            # a late authenticated PUT can never resurrect this old owner.
            # One hour exceeds the bounded upstream/network operation windows.
            db.execute(
                "INSERT INTO retired_owners VALUES(?,?,?,?) ON CONFLICT(user,device,registration_id) DO UPDATE SET expires=excluded.expires",
                (*auth[:2], registration_id, now + 3600),
            )
            deleted = db.execute(
                "DELETE FROM devices WHERE user=? AND device=? AND session=? AND registration_id=?",
                (*auth[:3], registration_id),
            ).rowcount
        if not deleted:
            return Response(status_code=204)
        return {"state": "unregistered"}

    def result(row):
        return {"state": row["state"], "expires_at": row["expires"]}

    def lookup(ref, auth):
        db.execute(
            "UPDATE calls SET state='expired' WHERE room=? AND call=? AND state IN ('sending','ringing','delivery_unknown') AND expires<=?",
            (ref.room_id, ref.call_id, int(clock())),
        )
        row = db.execute(
            "SELECT * FROM calls WHERE room=? AND call=?", (ref.room_id, ref.call_id)
        ).fetchone()
        if row is None or auth[0] not in (row["caller"], row["recipient"]):
            raise HTTPException(404, "call_not_found")
        return row

    def eligible(route):
        return matrix.eligible(route["user"], route["device"])

    def deliver(route, payload, voip, expires):
        # Never hold the database mutex during any external I/O.
        status = push.send(
            route["voip"] if voip else route["apns"], payload, voip, expires
        )
        if status == 410:
            with transaction():
                if voip:
                    db.execute(
                        "DELETE FROM devices WHERE user=? AND device=? AND voip=? AND session=? AND registration_id=?",
                        (
                            route["user"],
                            route["device"],
                            route["voip"],
                            route["session"],
                            route["registration_id"],
                        ),
                    )
                else:
                    db.execute(
                        "UPDATE devices SET apns=NULL WHERE user=? AND device=? AND apns=? AND session=? AND registration_id=?",
                        (
                            route["user"],
                            route["device"],
                            route["apns"],
                            route["session"],
                            route["registration_id"],
                        ),
                    )
        return status

    def cancel_route(route, body):
        if not route["apns"] or not eligible(route):
            return True
        with transaction():
            bound = db.execute(
                "SELECT 1 FROM devices WHERE user=? AND device=? AND session=? AND registration_id=? AND apns=?",
                (
                    route["user"],
                    route["device"],
                    route["session"],
                    route["registration_id"],
                    route["apns"],
                ),
            ).fetchone()
        if not bound:
            return True
        payload = {
            "aps": {"content-available": 1},
            "call_action": "end",
            "call_id": body.call_id,
            "room_id": body.room_id,
        }
        return deliver(route, payload, False, int(clock()) + 30) == 200

    def cancel_routes(routes, body):
        # FastAPI runs this only after sending the committed HTTP response.
        # One batch is bounded to 16 routes and a 30-second scheduling window;
        # each fixed upstream request separately has its eight-second timeout.
        deadline = time.monotonic() + 30
        for route in routes[:16]:
            if time.monotonic() >= deadline:
                break
            try:
                failed = not cancel_route(route, body)
            except Exception:
                failed = True
            if failed:
                with lock:
                    # Aggregate only; never persist/log identifiers or exceptions.
                    app.state.cancellation_failures = min(
                        app.state.cancellation_failures + 1, 1000000
                    )

    @app.post("/v1/calls", response_model=Result)
    def create(body: Call, background: BackgroundTasks, auth=Depends(identity)):
        user, device, fingerprint, token = auth
        if body.recipient == user or not body.recipient.endswith(
            ":" + settings.matrix_server_name
        ):
            raise HTTPException(403, "invalid_call_room")
        encrypted, members = matrix.room(token, body.room_id)
        if not encrypted or members != {user, body.recipient}:
            raise HTTPException(403, "invalid_call_room")
        now = int(clock())
        # Reserve before network checks. Concurrent participant actions can see
        # and claim this row immediately, and a repeated create never sends again.
        with transaction():
            cleanup(now)
            existing = db.execute(
                "SELECT * FROM calls WHERE room=? AND call=?",
                (body.room_id, body.call_id),
            ).fetchone()
            if existing:
                if (
                    existing["caller"] != user
                    or existing["expires"] <= now
                    or existing["recipient"] != body.recipient
                    or bool(existing["video"]) != body.video
                    or existing["state"]
                    not in ("ringing", "sending", "delivery_unknown")
                ):
                    raise HTTPException(409, "call_conflict")
                return result(existing)
            for subject in ("call:" + user, "receive:" + body.recipient):
                count = db.execute(
                    "SELECT amount FROM rates WHERE subject=? AND bucket=?",
                    (subject, now // 60),
                ).fetchone()
                if count and count[0] >= 6:
                    raise HTTPException(429, "rate_limited")
            routes = db.execute(
                "SELECT * FROM devices WHERE user=? AND updated>=? AND registration_id!='' ORDER BY device LIMIT 17",
                (body.recipient, now - 7 * 86400),
            ).fetchall()
            if len(routes) > 16:
                raise HTTPException(409, "device_limit")
            if not routes:
                raise HTTPException(409, "no_eligible_device")
            for subject in ("call:" + user, "receive:" + body.recipient):
                db.execute(
                    "INSERT INTO rates VALUES(?,?,1) ON CONFLICT(subject,bucket) DO UPDATE SET amount=amount+1",
                    (subject, now // 60),
                )
            db.execute(
                "INSERT INTO calls VALUES(?,?,?,?,?,?,?,NULL,?)",
                (
                    body.room_id,
                    body.call_id,
                    user,
                    body.recipient,
                    int(body.video),
                    now + 30,
                    "sending",
                    now,
                ),
            )
        successes, ambiguous, attempts = 0, False, 0
        for route in routes:
            with transaction():
                current = lookup(body, auth)
                if current["state"] != "sending":
                    break
            if not eligible(route):
                with transaction():
                    db.execute(
                        "DELETE FROM devices WHERE user=? AND device=? AND session=? AND voip=? AND registration_id=?",
                        (
                            route["user"],
                            route["device"],
                            route["session"],
                            route["voip"],
                            route["registration_id"],
                        ),
                    )
                continue
            with transaction():
                current = lookup(body, auth)
                if current["state"] != "sending":
                    break
                bound = db.execute(
                    "SELECT 1 FROM devices WHERE user=? AND device=? AND session=? AND voip=? AND registration_id=?",
                    (
                        route["user"],
                        route["device"],
                        route["session"],
                        route["voip"],
                        route["registration_id"],
                    ),
                ).fetchone()
                if not bound:
                    continue
                # A committed attempt is visible to end/answer before sending.
                # An in-flight request cannot be recalled; reconcile below after
                # it completes, with ordinary APNs only, if a terminal action won.
                db.execute(
                    "INSERT INTO deliveries VALUES(?,?,?,?,?,?)",
                    (
                        body.room_id,
                        body.call_id,
                        route["user"],
                        route["device"],
                        route["session"],
                        route["registration_id"],
                    ),
                )
            payload = {
                "aps": {},
                "call_id": body.call_id,
                "room_id": body.room_id,
                "video": body.video,
                "expires_at": now + 30,
            }
            status = deliver(route, payload, True, now + 30)
            attempts += 1
            successes += int(status == 200)
            ambiguous = ambiguous or status >= 500
            with transaction():
                current = lookup(body, auth)
                cancel = current["state"] in ("ended", "expired", "failed") or (
                    current["state"] == "answered"
                    and current["answer_device"] != route["device"]
                )
                current_route = db.execute(
                    "SELECT * FROM devices WHERE user=? AND device=? AND session=? AND registration_id=?",
                    (
                        route["user"],
                        route["device"],
                        route["session"],
                        route["registration_id"],
                    ),
                ).fetchone()
            if cancel and current_route and (status == 200 or status >= 500):
                background.add_task(cancel_routes, [current_route], body)
        with transaction():
            current = lookup(body, auth)
            if current["state"] == "sending":
                state = (
                    "ringing"
                    if successes
                    else ("delivery_unknown" if ambiguous else "failed")
                )
                db.execute(
                    "UPDATE calls SET state=? WHERE room=? AND call=? AND state='sending'",
                    (state, body.room_id, body.call_id),
                )
                current = lookup(body, auth)
            outcome = result(current)
        # A participant winning while delivery was in flight is authoritative.
        if outcome["state"] in ("answered", "ended", "expired"):
            return outcome
        if not successes:
            if not attempts:
                raise HTTPException(409, "no_eligible_device")
            raise HTTPException(502, "push_delivery_failed")
        return outcome

    def action(body, auth, answer, background):
        with transaction():
            cleanup(int(clock()))
            row = lookup(body, auth)
            if answer:
                if auth[0] != row["recipient"]:
                    raise HTTPException(403, "recipient_required")
                if row["state"] == "answered" and row["answer_device"] == auth[1]:
                    return result(row)
                if row["state"] not in ("ringing", "sending", "delivery_unknown"):
                    raise HTTPException(409, "call_not_ringing")
            elif row["state"] in ("ended", "expired", "failed"):
                return result(row)
            state = "answered" if answer else "ended"
            db.execute(
                "UPDATE calls SET state=?,answer_device=? WHERE room=? AND call=?",
                (
                    state,
                    auth[1] if answer else row["answer_device"],
                    body.room_id,
                    body.call_id,
                ),
            )
            routes = db.execute(
                "SELECT d.* FROM devices d JOIN deliveries v ON d.user=v.user AND d.device=v.device AND d.session=v.session AND d.registration_id=v.registration_id WHERE v.room=? AND v.call=?",
                (body.room_id, body.call_id),
            ).fetchall()
        background.add_task(
            cancel_routes,
            [route for route in routes if not (answer and route["device"] == auth[1])],
            body,
        )
        return {"state": state, "expires_at": row["expires"]}

    @app.post("/v1/calls/end", response_model=Result)
    def end(body: Reference, background: BackgroundTasks, auth=Depends(identity)):
        with transaction():
            exists = db.execute(
                "SELECT 1 FROM calls WHERE room=? AND call=?",
                (body.room_id, body.call_id),
            ).fetchone()
        if not exists:
            # A client may time out while create is still validating its room.
            # Only a freshly verified participant of the same encrypted two-user
            # local room may reserve a cancellation before that create arrives.
            encrypted, members = matrix.room(auth[3], body.room_id)
            if (
                not encrypted
                or len(members) != 2
                or auth[0] not in members
                or any(
                    not member.startswith("@")
                    or not member.endswith(":" + settings.matrix_server_name)
                    for member in members
                )
            ):
                raise HTTPException(403, "invalid_call_room")
            other = next(member for member in members if member != auth[0])
            now = int(clock())
            with transaction():
                exists = db.execute(
                    "SELECT 1 FROM calls WHERE room=? AND call=?",
                    (body.room_id, body.call_id),
                ).fetchone()
                if not exists:
                    subject = "cancel:" + auth[0]
                    count = db.execute(
                        "SELECT amount FROM rates WHERE subject=? AND bucket=?",
                        (subject, now // 60),
                    ).fetchone()
                    if count and count[0] >= 6:
                        raise HTTPException(429, "rate_limited")
                    db.execute(
                        "INSERT INTO rates VALUES(?,?,1) ON CONFLICT(subject,bucket) DO UPDATE SET amount=amount+1",
                        (subject, now // 60),
                    )
                    db.execute(
                        "INSERT INTO calls VALUES(?,?,?,?,?,?,?,NULL,?)",
                        (
                            body.room_id,
                            body.call_id,
                            auth[0],
                            other,
                            0,
                            now + 30,
                            "ended",
                            now,
                        ),
                    )
                    return {"state": "ended", "expires_at": now + 30}
        return action(body, auth, False, background)

    @app.post("/v1/calls/answer", response_model=Result)
    def answer(body: Reference, background: BackgroundTasks, auth=Depends(identity)):
        return action(body, auth, True, background)

    @app.get("/v1/calls/status", response_model=Result)
    def status(
        room_id: str = Query(
            min_length=3, max_length=255, pattern=r"^![^\s/]+:[^\s/]+$"
        ),
        call_id: str = Query(
            min_length=1, max_length=255, pattern=r"^[A-Za-z0-9._~+\-/=]+$"
        ),
        auth=Depends(identity),
    ):
        with transaction():
            return result(lookup(Reference(room_id=room_id, call_id=call_id), auth))

    return app


def production_app():
    required = (
        "MATRIX_URL",
        "MATRIX_SERVER_NAME",
        "MATRIX_ADMIN_TOKEN",
        "MATRIX_ADMIN_URL",
        "APNS_TEAM_ID",
        "APNS_KEY_ID",
    )
    if any(not os.environ.get(key) for key in required):
        raise RuntimeError("Missing required gateway configuration")
    if os.environ.get("APNS_ENVIRONMENT", "production") not in (
        "production",
        "sandbox",
    ):
        raise RuntimeError("Invalid APNs environment")
    # Production is Linux-only. A filesystem lease prevents accidental second
    # workers/replicas from running independent process-local route coordinators.
    import fcntl

    os.umask(0o077)
    database = os.environ.get("DATABASE_PATH", "/data/routes.sqlite")
    Path(database).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lease = open(database + ".lock", "a", encoding="utf-8")
    try:
        fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lease.close()
        raise RuntimeError(
            "Gateway requires exactly one worker per route database"
        ) from None
    app = create_app(
        Settings(
            database=database,
            matrix_url=os.environ["MATRIX_URL"],
            matrix_server_name=os.environ["MATRIX_SERVER_NAME"],
            matrix_admin_token=os.environ["MATRIX_ADMIN_TOKEN"],
            matrix_admin_url=os.environ["MATRIX_ADMIN_URL"],
            apns_team_id=os.environ["APNS_TEAM_ID"],
            apns_key_id=os.environ["APNS_KEY_ID"],
            apns_key_path=os.environ.get("APNS_KEY_PATH", "/run/secrets/apns.p8"),
            apns_sandbox=os.environ.get("APNS_ENVIRONMENT", "production") == "sandbox",
        )
    )
    app.state.process_lease = lease
    return app
