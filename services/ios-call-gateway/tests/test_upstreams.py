import base64
import json
import sys
from pathlib import Path

import httpx
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from fastapi import HTTPException

sys.path.insert(0, str(Path(__file__).parents[1]))
from gateway import APNs, Matrix, Settings


def test_fixed_matrix_auth_and_admin_device_validation():
    seen = []

    def handler(request):
        seen.append(request)
        path = request.url.path
        if path.endswith("whoami"):
            return httpx.Response(200, json={"user_id": "@b:test", "device_id": "B"})
        if path.endswith("/devices/B"):
            return httpx.Response(200, json={"device_id": "B"})
        return httpx.Response(200, json={"deactivated": False})

    matrix = Matrix(
        Settings(matrix_url="https://matrix.test", matrix_admin_token="ADMIN_SECRET")
    )
    matrix.client.close()
    matrix.client = httpx.Client(
        base_url="https://matrix.test", transport=httpx.MockTransport(handler)
    )
    matrix.admin_client.close()
    matrix.admin_client = httpx.Client(
        base_url="http://synapse:8008", transport=httpx.MockTransport(handler)
    )
    assert matrix.identity("USER_SECRET") == ("@b:test", "B")
    assert matrix.eligible("@b:test", "B")
    assert seen[0].headers["authorization"] == "Bearer USER_SECRET"
    assert all(r.headers["authorization"] == "Bearer ADMIN_SECRET" for r in seen[1:])
    assert seen[0].url.host == "matrix.test"
    assert all(r.url.host == "synapse" and "SECRET" not in str(r.url) for r in seen[1:])


@pytest.mark.parametrize("status,expected", [(401, 401), (500, 503), (302, 503)])
def test_matrix_fail_closed(status, expected):
    matrix = Matrix(Settings(matrix_url="https://matrix.test"))
    matrix.client.close()
    matrix.client = httpx.Client(
        base_url="https://matrix.test",
        transport=httpx.MockTransport(
            lambda req: httpx.Response(status, json={"secret": "NEVER_ECHO"})
        ),
    )
    with pytest.raises(HTTPException) as error:
        matrix.identity("TOKEN")
    assert error.value.status_code == expected
    assert "NEVER_ECHO" not in str(error.value.detail)


def test_apns_headers_signature_and_minimal_body(tmp_path, monkeypatch):
    key = ec.generate_private_key(ec.SECP256R1())
    keyfile = tmp_path / "test-key.p8"
    keyfile.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    # Inject before constructor, so this test needs no HTTP2/network connection.
    seen = []
    original = httpx.Client
    monkeypatch.setattr(
        httpx,
        "Client",
        lambda **kwargs: original(
            base_url=kwargs["base_url"],
            transport=httpx.MockTransport(
                lambda r: seen.append(r) or httpx.Response(200)
            ),
        ),
    )
    apns = APNs(
        Settings(apns_key_path=str(keyfile), apns_key_id="KEY_ID", apns_team_id="TEAM")
    )
    payload = {
        "aps": {},
        "room_id": "!r:test",
        "call_id": "c",
        "video": False,
        "expires_at": 1234,
    }
    assert apns.send("a" * 64, payload, True, 1234) == 200
    request = seen[0]
    assert request.url.host == "api.push.apple.com"
    assert request.headers["apns-topic"] == "com.liuhetong.liuhetongMobile.voip"
    assert request.headers["apns-push-type"] == "voip"
    assert request.headers["apns-priority"] == "10"
    assert request.headers["apns-expiration"] == "1234"
    assert json.loads(request.content) == payload
    jwt = request.headers["authorization"].split()[1]
    header, body, sig = jwt.split(".")
    signature = base64.urlsafe_b64decode(sig + "==")
    key.public_key().verify(
        encode_dss_signature(
            int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big")
        ),
        (header + "." + body).encode(),
        ec.ECDSA(hashes.SHA256()),
    )
    assert (
        apns.send(
            "b" * 64,
            {"aps": {"content-available": 1}, "call_action": "end"},
            False,
            1234,
        )
        == 200
    )
    assert seen[1].headers["apns-topic"] == "com.liuhetong.liuhetongMobile"
    assert seen[1].headers["apns-push-type"] == "background"
    assert seen[1].headers["apns-priority"] == "5"


def test_admin_credential_uses_only_fixed_private_origin(monkeypatch):
    from urllib.parse import urlparse

    clients = []
    seen = []
    original = httpx.Client

    def handler(request):
        seen.append(request)
        if request.url.path.endswith("whoami"):
            return httpx.Response(200, json={"user_id": "@b:test", "device_id": "B"})
        if request.url.path.endswith("/devices/B"):
            return httpx.Response(200, json={"device_id": "B"})
        return httpx.Response(200, json={"deactivated": False})

    def factory(**kwargs):
        clients.append(kwargs)
        return original(
            base_url=kwargs["base_url"], transport=httpx.MockTransport(handler)
        )

    monkeypatch.setattr(httpx, "Client", factory)
    matrix = Matrix(
        Settings(
            matrix_url="https://public.test",
            matrix_admin_url="http://synapse:8008",
            matrix_admin_token="ADMIN_SECRET",
        )
    )
    assert matrix.identity("USER_SECRET") == ("@b:test", "B")
    assert matrix.eligible("@b:test", "B")
    assert seen[0].url.host == "public.test"
    assert all(
        r.url.host == "synapse"
        and r.url.port == 8008
        and r.headers["authorization"] == "Bearer ADMIN_SECRET"
        for r in seen[1:]
    )
    assert all(
        c["follow_redirects"] is False and c["trust_env"] is False for c in clients
    )
    assert {urlparse(c["base_url"]).hostname for c in clients} == {
        "public.test",
        "synapse",
    }


@pytest.mark.parametrize(
    "origin",
    [
        "http://public.test:8008",
        "https://public.test",
        "http://synapse:8009",
        "http://user:pass@synapse:8008",
        "http://synapse:8008/path",
        "http://synapse:8008?next=public.test",
        "http://synapse:8008#fragment",
        "http://synapse.evil:8008",
    ],
)
def test_unsafe_admin_origin_rejected(origin):
    with pytest.raises(ValueError):
        Matrix(Settings(matrix_admin_url=origin))


def test_private_admin_redirect_is_not_followed_or_exposed():
    seen = []
    matrix = Matrix(Settings(matrix_admin_token="ADMIN_SECRET"))
    matrix.admin_client.close()
    matrix.admin_client = httpx.Client(
        base_url="http://synapse:8008",
        follow_redirects=False,
        trust_env=False,
        transport=httpx.MockTransport(
            lambda request: (
                seen.append(request)
                or httpx.Response(
                    302,
                    headers={"Location": "https://public.test/steal"},
                    json={"secret": "NEVER_ECHO"},
                )
            )
        ),
    )
    with pytest.raises(HTTPException) as error:
        matrix.eligible("@b:test", "B")
    assert error.value.status_code == 503
    assert len(seen) == 1 and seen[0].url.host == "synapse"
    assert "NEVER_ECHO" not in str(error.value.detail)
