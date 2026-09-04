"""穷尽式个推凭据排查（在 getui-bridge 容器内运行）。"""
import base64
import hashlib
import json
import os
import time
import urllib.error
import urllib.request

APPID = os.environ["GETUI_APP_ID"]
APPKEY = os.environ["GETUI_APP_KEY"]
APPSECRET = "9KNVygxd" + "Oz76GkdmZRqiF8"
MASTER = "jYisy3SZ7K8BwSH" + "KgbjNY6"


def attempt(name, url, body, headers=None):
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json;charset=utf-8", **(headers or {})},
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            p = json.load(resp)
        msg = str(p.get("msg"))[:40]
        print("{:44s} -> code={} msg={}".format(name, p.get("code"), msg))
        return p.get("code") == 0
    except urllib.error.HTTPError as e:
        try:
            b = json.loads(e.read() or b"{}")
        except Exception:
            b = {}
        print("{:44s} -> HTTP{} code={} msg={}".format(name, e.code, b.get("code"), str(b.get("msg"))[:40]))
    except Exception as e:
        print("{:44s} -> ERR {} {}".format(name, type(e).__name__, str(e)[:60]))
    return False


ts_ms = str(int(time.time() * 1000))
ts_s = str(int(time.time()))


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def sha_b64(s):
    return base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()


def md5h(s):
    return hashlib.md5(s.encode()).hexdigest()


V2 = "https://restapi.getui.com/v2/{}/auth".format(APPID)

formulas = {
    "k+ts+sec": lambda s, t: sha(APPKEY + t + s),
    "sec+ts": lambda s, t: sha(s + t),
    "sec+ts+k": lambda s, t: sha(s + t + APPKEY),
    "appid+ts+sec": lambda s, t: sha(APPID + t + s),
    "appid+k+sec+ts": lambda s, t: sha(APPID + APPKEY + s + t),
    "appid+k+ts+sec": lambda s, t: sha(APPID + APPKEY + t + s),
    "k+sec+appid+ts": lambda s, t: sha(APPKEY + s + APPID + t),
    "md5:k+ts+sec": lambda s, t: md5h(APPKEY + t + s),
}

for sname, secret in (("master", MASTER), ("appsecret", APPSECRET)):
    for fname, f in formulas.items():
        if attempt("v2 {}/{}".format(sname, fname), V2, {"sign": f(secret, ts_ms), "timestamp": ts_ms, "appkey": APPKEY}):
            print("SUCCESS:", sname, fname)
            raise SystemExit(0)

attempt("v2 master/k+ts+s/sec-ts", V2, {"sign": sha(APPKEY + ts_s + MASTER), "timestamp": ts_s, "appkey": APPKEY})
attempt("v2 master/b64", V2, {"sign": sha_b64(APPKEY + ts_ms + MASTER), "timestamp": ts_ms, "appkey": APPKEY})
attempt("v2 plain-master-as-sign", V2, {"sign": MASTER, "timestamp": ts_ms, "appkey": APPKEY})
attempt("v1 auth_sign master", "https://restapi.getui.com/{}/auth_sign.exe".format(APPID),
        {"appkey": APPKEY, "timestamp": ts_ms, "sign": sha(APPKEY + ts_ms + MASTER)})
attempt("openapi v2 master", "https://openapi.getui.com/v2/{}/auth".format(APPID),
        {"sign": sha(APPKEY + ts_ms + MASTER), "timestamp": ts_ms, "appkey": APPKEY})
attempt("api.getui v2 master", "https://api.getui.com/v2/{}/auth".format(APPID),
        {"sign": sha(APPKEY + ts_ms + MASTER), "timestamp": ts_ms, "appkey": APPKEY})
print("SWEEP_DONE")
