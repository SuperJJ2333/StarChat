"""生产端到端复现：带图朋友圈 发布→feed→图片URL可达性（容器内执行）。"""
import json, os, sys, urllib.error, urllib.request
from datetime import datetime, timezone
from uuid import uuid4
sys.path.insert(0, "/opt/business-api")
from sqlalchemy import create_engine, text
from app.core.config import Settings
from app.core.database import create_session_factory

settings = Settings(_env_file=None, environment="production")
engine = create_engine(os.environ["BUSINESS_DATABASE_URL"])
factory = create_session_factory(engine)
now = datetime.now(timezone.utc)
with factory() as session:
    row = session.execute(text(
        "select u.id, d.id as device_id, f.id as family_id from users u "
        "join user_roles r on r.user_id=u.id and r.role_code='SUPER_ADMIN' "
        "join identity_devices d on d.user_id=u.id and d.revoked_at is null "
        "join refresh_token_families f on f.device_id=d.id and f.revoked_at is null "
        "where u.username='liuhetong_admin' and u.status='ACTIVE' limit 1")).first()
    assert row, "no admin session"
    user_id, device_id, family_id = row
import jwt
CLEANUP_ONLY = "--cleanup" in sys.argv
claims = {"sub": user_id, "device_id": device_id, "family_id": family_id,
          "iss": os.environ.get("BUSINESS_JWT_ISSUER", "liuhetong"),
          "iat": int(now.timestamp()), "exp": int(now.timestamp()) + 300,
          "jti": str(uuid4())}
token = jwt.encode(claims, os.environ["BUSINESS_JWT_SECRET"], algorithm="HS256")
H = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}

def call(method, path, payload=None, raw=None, ctype=None):
    data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
    headers = dict(H)
    headers["Idempotency-Key"] = str(uuid4())
    if ctype: headers["Content-Type"] = ctype
    req = urllib.request.Request("http://127.0.0.1:8082" + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read()
            return r.status, (json.loads(body) if body and body[:1] in (b'{', b'[') else body[:80])
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

if CLEANUP_ONLY:
    H2 = {"Authorization": "Bearer " + jwt.encode(
        {"sub": user_id, "device_id": device_id, "family_id": family_id,
         "iss": os.environ.get("BUSINESS_JWT_ISSUER", "liuhetong"),
         "iat": int(now.timestamp()), "exp": int(now.timestamp()) + 300,
         "jti": str(uuid4())},
        os.environ["BUSINESS_JWT_SECRET"], algorithm="HS256")}
    def call2(method, path):
        h2 = dict(H2)
        h2["Idempotency-Key"] = "cleanup-" + uuid4().hex
        req = urllib.request.Request("http://127.0.0.1:8082" + path, headers=h2, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
    s, feed = call2("GET", "/api/v1/moments/feed?mode=latest&limit=50")
    print("CLEANUP_FEED_STATUS", s, "len", len(feed))
    items = json.loads(feed).get("items", []) if s == 200 else []
    print("CLEANUP_FEED_ITEMS", len(items))
    removed = 0
    for item in items:
        print("SCAN", item["id"][:8], repr(item.get("text", ""))[:40], item.get("status"))
        if item.get("text", "").startswith("e2e 带图"):
            ds, _ = call2("DELETE", f"/api/v1/moments/{item['id']}")
            print("DELETE", item["id"][:8], ds)
            removed += ds == 204
    print("CLEANUP_REMOVED", removed)
    sys.exit(0)

# 1) 上传一张最小 JPEG（1x1）
JPEG = bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffdb004300ffd9')
s, begun = call("POST", "/api/v1/moments/media/uploads",
                {"file_name": "e2e.jpg", "mime_type": "image/jpeg", "byte_size": len(JPEG)})
print("BEGIN", s, json.dumps(begun, ensure_ascii=False)[:200])
uid = begun.get("id")
upload_url = begun.get("upload_url") or ""
print("UPLOAD_URL_FIELD", upload_url[:120])
s2, _ = call("PUT", f"/api/v1/moments/media/uploads/{uid}/content", raw=JPEG, ctype="image/jpeg")
print("PUT", s2)
s3, done = call("POST", f"/api/v1/moments/media/uploads/{uid}/complete")
print("COMPLETE", s3, json.dumps(done, ensure_ascii=False)[:300])
media_url = (done.get("media_url") or "").strip()

# 2) 发布带图动态
s4, pub = call("POST", "/api/v1/moments", {"text": "e2e 带图复现", "visibility": "PUBLIC", "image_urls": [media_url]})
print("PUBLISH", s4, json.dumps(pub, ensure_ascii=False)[:200])
mid = pub.get("id")

# 3) feed 校验
s5, feed = call("GET", "/api/v1/moments/feed?mode=latest")
items = feed.get("items", [])
mine = [i for i in items if i.get("id") == mid]
print("FEED_HAS_ITEM", bool(mine))
if mine:
    print("ITEM_KEYS", sorted(mine[0].keys()))
    print("IMAGE_URLS", mine[0].get("image_urls"))
    print("STATUS", mine[0].get("status"))

# 4) 图片 URL 公网可达性（用 feed 返回的完整 URL 原样探测）
if mine and mine[0].get("image_urls"):
    public_url = mine[0]["image_urls"][0]
    print("PROBE_URL_TTL", "604800" if "expires_in=604800" in public_url else ("300" if "expires_in=300" in public_url else "other"))
    req = urllib.request.Request(public_url)
    try:
        r = urllib.request.urlopen(req, timeout=15)
        body = r.read()
        print("MEDIA_PROBE", r.status, len(body), "bytes, jpeg" if body[:2] == bytes([255, 216]) else body[:4])
    except urllib.error.HTTPError as e:
        print("MEDIA_PROBE_HTTP", e.code)
    except Exception as e:
        print("MEDIA_PROBE_ERR", e)
