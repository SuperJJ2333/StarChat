"""在 synapse 容器内精确复刻 rest/admin/users.py 的注册 HMAC 路径。"""
import hashlib
import hmac
import json
import re
import urllib.error
import urllib.request

BASE = "http://localhost:8008"
raw = open("/data/homeserver.yaml").read()
SECRET = re.search(r'registration_shared_secret: "([^"]+)"', raw).group(1)
SEP = b"\x00"
print("secret_len", len(SECRET))


def nonce():
    with urllib.request.urlopen(BASE + "/_synapse/admin/v1/register") as r:
        return json.loads(r.read())["nonce"]


def register(username, password):
    n = nonce()
    want = hmac.new(SECRET.encode(), digestmod=hashlib.sha1)
    want.update(n.encode("utf8"))
    want.update(SEP)
    want.update(username.encode("utf8"))
    want.update(SEP)
    want.update(password.encode("utf8"))
    want.update(SEP)
    want.update(b"notadmin")
    body = json.dumps({
        "nonce": n,
        "username": username,
        "password": password,
        "mac": want.hexdigest(),
        "admin": False,
    }).encode()
    req = urllib.request.Request(BASE + "/_synapse/admin/v1/register", data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:140]


result = register("rotate-repl-test", "verify")
print("REPL_REGISTER", result)
