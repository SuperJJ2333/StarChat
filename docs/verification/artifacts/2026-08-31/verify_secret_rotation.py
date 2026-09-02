"""registration_shared_secret 轮换验证：旧密钥拒绝、新密钥可注册。"""
import hashlib
import hmac
import json
import re
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8008"
raw = open("/data/homeserver.yaml").read()
NEW = re.search(r'registration_shared_secret: "([^"]+)"', raw).group(1)
OLD = "change-this-registration-shared-secret"
SEP = chr(0)


def nonce():
    with urllib.request.urlopen(BASE + "/_synapse/admin/v1/register") as r:
        return json.loads(r.read())["nonce"]


def try_register(secret, username):
    n = nonce()
    payload = SEP.join([n, username, "pass", "notadmin"])
    mac = hmac.new(secret.encode(), payload.encode(), hashlib.sha1).hexdigest()
    body = json.dumps({"nonce": n, "username": username, "password": "verify", "mac": mac, "admin": False}).encode()
    req = urllib.request.Request(BASE + "/_synapse/admin/v1/register", data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        print("REGISTER_HTTP", e.code, e.read().decode("utf-8", "replace")[:160])
        return e.code


old_result = try_register(OLD, "rotate-verify-old")
new_result = try_register(NEW, "rotate-verify-new")
print("OLD_SECRET_REGISTER:", old_result, "(expect 403)")
print("NEW_SECRET_REGISTER:", new_result, "(expect 201)")
print("ROTATION_VERIFY:", "PASS" if old_result == 403 and new_result == 201 else "FAIL")
