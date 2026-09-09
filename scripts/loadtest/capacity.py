"""Prepare and operate ONLY a marked, local disposable Synapse capacity stack.

No production configuration is read. Runtime credentials and server data live
under docs/verification/artifacts. Console/results contain no tokens or bodies.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "docs/verification/artifacts"
COMPOSE = Path(__file__).with_name("compose.isolated.yml")
SERVER = "capacity.localhost"


def validate_origin(value: str) -> str:
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError("Invalid local target port") from error
    if (parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
            or parsed.username or parsed.password or parsed.path not in {"", "/"}
            or parsed.query or parsed.fragment or (port is not None and not 1 <= port <= 65535)):
        raise ValueError("Only a loopback isolated HTTP origin is allowed")
    return value.rstrip("/")


def artifact_path(path: Path) -> Path:
    resolved = path.resolve()
    if not resolved.is_relative_to(ARTIFACTS.resolve()) or resolved == ARTIFACTS.resolve():
        raise ValueError("Run directory must stay below docs/verification/artifacts")
    if any(character in str(resolved) for character in "\r\n$"):
        raise ValueError("Run directory cannot contain dotenv control characters")
    return resolved


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass  # Windows inherits the workspace ACL; do not claim chmod is an ACL.


def nginx_config(run_id: str, worker: bool) -> str:
    target = "synapse-sync-worker:8081" if worker else "synapse:8008"
    identity = json.dumps({"run_id": run_id, "server_name": SERVER}, separators=(",", ":"))
    return f"""server {{
  listen 8080;
  server_name _;
  client_max_body_size 50m;
  access_log off;
  location = /_capacity/identity {{ default_type application/json; return 200 '{identity}'; }}
  location ~ ^/_matrix/client/(r0|v3)/(sync|events)$ {{
    proxy_pass http://{target};
    proxy_read_timeout 75s;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
  }}
  location / {{
    proxy_pass http://synapse:8008;
    proxy_read_timeout 75s;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $remote_addr;
  }}
}}
"""


def prepare(path: Path) -> dict:
    path = artifact_path(path)
    if path.exists() and any(path.iterdir()):
        raise ValueError("Refusing to overwrite an existing run directory")
    path.mkdir(parents=True, exist_ok=True)
    (path / ".gitignore").write_text("*\n!.gitignore\n", encoding="utf-8")
    (path / "synapse").mkdir()
    (path / "postgres").mkdir()
    run_id = "capacity-" + secrets.token_hex(6)
    password = secrets.token_hex(24)
    registration = secrets.token_hex(32)
    info = {"run_id": run_id, "project": "chatflow-" + run_id,
            "server_name": SERVER, "base_url": "http://127.0.0.1:18008",
            "baseline_url": "http://127.0.0.1:18009", "created_at": datetime.now(timezone.utc).isoformat()}
    config = {
        "server_name": SERVER, "public_baseurl": info["base_url"],
        "pid_file": "/data/homeserver.pid", "report_stats": False,
        "listeners": [
            {"port": 8008, "type": "http", "tls": False, "x_forwarded": True,
             "bind_addresses": ["0.0.0.0"], "resources": [{"names": ["client", "media"], "compress": False}]},
            {"port": 9093, "type": "http", "tls": False, "bind_addresses": ["0.0.0.0"],
             "resources": [{"names": ["replication"]}]}],
        "database": {"name": "psycopg2", "args": {"user": "synapse", "password": password,
            "database": "synapse", "host": "postgres", "port": 5432, "cp_min": 5, "cp_max": 30}},
        "redis": {"enabled": True, "host": "matrix-redis", "port": 6379},
        "presence": {"enabled": False},
        "rc_invites": {"per_room": {"per_second": 50, "burst_count": 1200}},
        "enable_registration": False, "registration_shared_secret": registration,
        "macaroon_secret_key": secrets.token_hex(32), "form_secret": secrets.token_hex(32),
        "signing_key_path": f"/data/{SERVER}.signing.key", "log_config": "/data/log.config",
        "media_store_path": "/data/media_store", "enable_media_repo": True,
        "max_upload_size": "50M", "url_preview_enabled": False,
        "federation_domain_whitelist": [], "trusted_key_servers": [],
        "suppress_key_server_warning": True, "allow_public_rooms_over_federation": False,
        "allow_public_rooms_without_auth": False, "push": {"include_content": False},
    }
    worker = {"worker_app": "synapse.app.generic_worker", "worker_name": "sync-worker-1",
        "worker_pid_file": "/data/sync-worker-1.pid", "worker_log_config": "/data/log.config",
        "instance_map": {"main": {"host": "synapse", "port": 9093}},
        "worker_listeners": [{"port": 8081, "type": "http", "tls": False, "x_forwarded": True,
            "bind_addresses": ["0.0.0.0"], "resources": [{"names": ["client", "replication"], "compress": False}]}],
        "database": {"name": "psycopg2", "args": {**config["database"]["args"], "cp_max": 15}}}
    write_json(path / "isolation.json", info)
    write_json(path / "synapse/homeserver.yaml", config)  # JSON is a YAML subset.
    write_json(path / "synapse/worker-sync.yaml", worker)
    write_json(path / "synapse/log.config", {"version": 1,
        "formatters": {"brief": {"format": "%(asctime)s %(levelname)s %(name)s %(message)s"}},
        "handlers": {"console": {"class": "logging.StreamHandler", "formatter": "brief"}},
        "root": {"level": "WARNING", "handlers": ["console"]}, "disable_existing_loggers": False})
    # Synapse's signing key file format uses a base64 encoded 32-byte seed.
    import base64
    (path / "synapse" / f"{SERVER}.signing.key").write_text(
        "ed25519 capacity " + base64.b64encode(secrets.token_bytes(32)).decode().rstrip("=") + "\n", encoding="utf-8")
    for label in ["worker", "baseline"]:
        (path / f"gateway-{label}.conf").write_text(nginx_config(run_id, label == "worker"), encoding="utf-8")
    env = {"CAPACITY_PROJECT": info["project"], "CAPACITY_RUN_DIR": path.as_posix(),
        "CAPACITY_RUN_ID": run_id, "CAPACITY_DB_PASSWORD": password,
        "CAPACITY_ISOLATED_TEST": "YES", "CAPACITY_MEDIA_DEDUP": "true"}
    (path / "compose.env").write_text("".join(f"{key}={value}\n" for key, value in env.items()), encoding="utf-8")
    for private in [path / "compose.env", path / "synapse" / f"{SERVER}.signing.key"]:
        try:
            private.chmod(0o600)
        except OSError:
            pass
    return info


def load_run(path: Path) -> tuple[Path, dict]:
    path = artifact_path(path)
    info = json.loads((path / "isolation.json").read_text(encoding="utf-8"))
    if (info.get("server_name") != SERVER or not re.fullmatch(r"capacity-[a-f0-9]{12}", info.get("run_id", ""))
            or info.get("project") != "chatflow-" + info["run_id"]):
        raise ValueError("Not a marked isolated capacity run")
    validate_origin(info["base_url"])
    validate_origin(info["baseline_url"])
    values = dict(line.split("=", 1) for line in (path / "compose.env").read_text(encoding="utf-8").splitlines() if "=" in line)
    if (Path(values.get("CAPACITY_RUN_DIR", "")).resolve() != path
            or values.get("CAPACITY_RUN_ID") != info["run_id"]
            or values.get("CAPACITY_PROJECT") != info["project"]
            or values.get("CAPACITY_ISOLATED_TEST") != "YES"):
        raise ValueError("Compose environment no longer matches the isolated run")
    return path, info


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class LocalApi:
    def __init__(self, origin: str):
        self.origin = validate_origin(origin)
        self.rate_limit_retries = 0
        self.rate_limit_wait_ms = 0

    def request(self, method, path, token=None, body=None, *, raw=False, expected=(200,), retry_rate_limit=False):
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("API path must be local")
        data = body if raw else (json.dumps(body).encode("utf-8") if body is not None else None)
        headers = {"Content-Type": "application/octet-stream" if raw else "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = Request(self.origin + path, data=data, headers=headers, method=method)
        # No environment proxy and no redirects, including redirects to production.
        opener = build_opener(ProxyHandler({}), NoRedirects())
        retry_deadline = time.monotonic() + 120
        retries = 0
        while True:
            try:
                with opener.open(request, timeout=40) as response:
                    status, content = response.status, response.read()
            except HTTPError as error:
                status, content = error.code, error.read()
            except (URLError, TimeoutError, OSError):
                raise RuntimeError("Isolated HTTP request failed; no response body logged") from None
            if status != 429 or not retry_rate_limit:
                break
            try:
                milliseconds = json.loads(content).get("retry_after_ms", 1000)
            except (ValueError, AttributeError):
                milliseconds = 1000
            if type(milliseconds) is not int or milliseconds < 0:
                milliseconds = 1000
            wait = max(1, milliseconds) / 1000
            if retries >= 12 or time.monotonic() + wait > retry_deadline:
                raise RuntimeError("Bootstrap rate-limit retry budget exhausted")
            retries += 1
            self.rate_limit_retries += 1
            self.rate_limit_wait_ms += int(wait * 1000)
            time.sleep(wait)
        if status not in expected:
            raise RuntimeError(f"Isolated {method} operation returned HTTP {status}")
        if raw:
            return status, content
        return json.loads(content) if content else {}


def probe(api: LocalApi, info: dict) -> None:
    identity = api.request("GET", "/_capacity/identity")
    if identity != {"run_id": info["run_id"], "server_name": SERVER}:
        raise ValueError("Isolation identity does not match; refusing further requests")
    api.request("GET", "/_matrix/client/versions")


def register(api: LocalApi, secret: str, username: str, admin=False) -> dict:
    nonce = api.request("GET", "/_synapse/admin/v1/register", retry_rate_limit=True)["nonce"]
    password = secrets.token_urlsafe(24)
    payload = "\x00".join([nonce, username, password, "admin" if admin else "notadmin"])
    mac = hmac.new(secret.encode(), payload.encode(), hashlib.sha1).hexdigest()
    response = api.request("POST", "/_synapse/admin/v1/register", body={
        "nonce": nonce, "username": username, "password": password, "admin": admin, "mac": mac}, retry_rate_limit=True)
    if response.get("user_id") != f"@{username}:{SERVER}":
        raise ValueError("Registration did not return the isolated server identity")
    return {"user_id": response["user_id"], "access_token": response["access_token"],
            "device_id": response.get("device_id")}


def bootstrap(path: Path, count: int) -> dict:
    path, info = load_run(path)
    if not 2 <= count <= 500:
        raise ValueError("Prepare between 2 and 500 independent accounts")
    if (path / "accounts.json").exists() or (path / "admin.json").exists():
        raise ValueError("Run already has credentials; create a new run instead of overwriting")
    api = LocalApi(info["base_url"])
    probe(api, info)
    config = json.loads((path / "synapse/homeserver.yaml").read_text(encoding="utf-8"))
    prefix = info["run_id"].replace("-", "")
    admin = register(api, config["registration_shared_secret"], prefix + "admin", admin=True)
    write_json(path / "admin.json", admin)
    rooms = []
    for label in ["transport", "membership"]:
        room = api.request("POST", "/_matrix/client/v3/createRoom", admin["access_token"], {
            "name": f"Isolated {label} fixture", "preset": "public_chat", "visibility": "private",
            "creation_content": {"m.federate": False},
            "initial_state": [{"type": "m.room.encryption", "state_key": "",
                "content": {"algorithm": "m.megolm.v1.aes-sha2"}},
                {"type": "m.room.history_visibility", "state_key": "", "content": {"history_visibility": "joined"}}]}, retry_rate_limit=True)
        rooms.append(room["room_id"])
    accounts = []
    for index in range(count):
        account = register(api, config["registration_shared_secret"], prefix + f"vu{index + 1:04}")
        api.request("POST", f"/_matrix/client/v3/join/{quote(rooms[0], safe='')}", account["access_token"], {}, retry_rate_limit=True)
        account.update(room_id=rooms[0], join_room_id=rooms[1])
        accounts.append(account)
        # Durable partial progress prevents accidental re-registration after an interrupted bootstrap.
        write_json(path / "accounts.json", accounts)
    result = {"accounts": count, "rooms": 2, "room_encryption": "m.megolm.v1.aes-sha2",
              "bootstrap_rate_limit_retries": api.rate_limit_retries, "bootstrap_rate_limit_wait_ms": api.rate_limit_wait_ms,
              "scope": "Registered isolated transport identities; no device-key exchange or E2EE correctness claim"}
    write_json(path / "bootstrap-result.json", result)
    return result


def local_docker(args: list[str], *, env=None, capture=False):
    environment = dict(os.environ if env is None else env)
    context = environment.get("DOCKER_CONTEXT")
    endpoint = environment.get("DOCKER_HOST")
    if context or not endpoint:
        # Context inspection reads local metadata only, before any daemon action.
        inspected = subprocess.run(["docker", "context", "inspect", *([context] if context else [])],
            env=environment, check=True, text=True, capture_output=True)
        try:
            endpoint = json.loads(inspected.stdout)[0]["Endpoints"]["docker"]["Host"]
        except (ValueError, KeyError, IndexError, TypeError) as error:
            raise ValueError("Cannot resolve a local Docker endpoint") from error
    unix = isinstance(endpoint, str) and re.fullmatch(r"unix:///[^\s?#\\]+", endpoint)
    pipe = isinstance(endpoint, str) and re.fullmatch(r"npipe:////\./pipe/[A-Za-z0-9_.-]+", endpoint)
    if not (unix or pipe):
        raise ValueError("Only a local Docker endpoint (Unix socket or Windows named pipe) is allowed")
    # Pin the verified endpoint: neither inherited context nor TLS settings can
    # redirect the following command if Docker's current context changes.
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"):
        environment.pop(key, None)
    return subprocess.run(["docker", "--host", endpoint, *args], env=environment,
        check=True, text=True, capture_output=capture)


def compose(path: Path, args: list[str], overrides=None, *, capture=False):
    path, info = load_run(path)
    env = {key: value for key, value in os.environ.items() if not key.startswith("CAPACITY_")}
    env.update(overrides or {})
    command = ["compose", "--env-file", str(path / "compose.env"), "-f", str(COMPOSE),
               "--project-name", info["project"], *args]
    return local_docker(command, env=env, capture=capture)


def wait_ready(api: LocalApi, info: dict, seconds=120):
    deadline = time.monotonic() + seconds
    while True:
        try:
            probe(api, info)
            return
        except (RuntimeError, ValueError):
            if time.monotonic() >= deadline:
                raise RuntimeError("Isolated server did not become ready") from None
            time.sleep(1)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def media_check(path: Path, flag_off=False) -> dict:
    path, info = load_run(path)
    api = LocalApi(info["base_url"])
    probe(api, info)
    accounts = json.loads((path / "accounts.json").read_text(encoding="utf-8"))
    admin = json.loads((path / "admin.json").read_text(encoding="utf-8"))["access_token"]
    if len(accounts) < 2:
        raise ValueError("Media lifecycle test needs at least two isolated users")
    a, b = accounts[:2]
    payload = secrets.token_bytes(4096)  # Opaque synthetic upload, not an E2EE message or real user file.

    def upload(account, value):
        _, response = api.request("POST", "/_matrix/media/v3/upload?filename=opaque-fixture.bin",
            account["access_token"], value, raw=True)
        return json.loads(response)["content_uri"]

    def list_ids(account):
        body = api.request("GET", f"/_synapse/admin/v1/users/{quote(account['user_id'], safe='')}/media?limit=100", admin)
        return {entry["media_id"] for entry in body["media"]}

    def delete_reference(account):
        return api.request("DELETE", f"/_synapse/admin/v1/users/{quote(account['user_id'], safe='')}/media?limit=100", admin)

    def download(uri, account):
        server, media = uri.removeprefix("mxc://").split("/", 1)
        return api.request("GET", f"/_matrix/client/v1/media/download/{quote(server,safe='')}/{quote(media,safe='')}",
            account["access_token"], raw=True)[1]

    first, second = upload(a, payload), upload(b, payload)
    if first != second:
        raise AssertionError("Different users did not receive the same canonical MXC")
    media_id = first.rsplit("/", 1)[1]
    require(media_id in list_ids(a) and media_id in list_ids(b), "Uploader references missing")
    delete_reference(a)
    require(media_id not in list_ids(a) and media_id in list_ids(b), "User deletion crossed reference boundary")
    require(download(first, b) == payload, "Shared payload was deleted while another reference remained")
    delete_reference(b)
    require(upload(a, payload) == first, "Logical deletion prevented canonical reuse")
    concurrent_payload = secrets.token_bytes(4096)
    with ThreadPoolExecutor(max_workers=8) as pool:
        concurrent = list(pool.map(lambda index: upload(accounts[index % 2], concurrent_payload), range(8)))
    require(len(set(concurrent)) == 1, "Concurrent uploads published multiple canonical MXCs")
    quarantine = f"/_synapse/admin/v1/media/quarantine/{SERVER}/{quote(media_id,safe='')}"
    api.request("POST", quarantine, admin, {})
    api.request("POST", "/_matrix/media/v3/upload", b["access_token"], payload, raw=True, expected=(403,))
    result = {"same_mxc_cross_user": True, "independent_reference_deletion": True,
        "retained_blob_reuse": True, "concurrent_uploads": 8, "quarantine_reupload_rejected": True,
        "flag_off": "not run", "scope": "Real HTTP Synapse/PostgreSQL media lifecycle; synthetic opaque bytes"}
    if flag_off:
        try:
            # Recreate gateways too: nginx resolves upstream container IPs at start.
            compose(path, ["up", "-d", "--force-recreate", "synapse", "synapse-sync-worker", "gateway-worker", "gateway-baseline"], {"CAPACITY_MEDIA_DEDUP": "false"})
            wait_ready(api, info)
            other = secrets.token_bytes(4096)
            require(upload(a, other) != upload(b, other), "Flag-off still deduplicates new uploads")
            api.request("POST", "/_matrix/media/v3/upload", b["access_token"], payload, raw=True, expected=(403,))
            require(download(concurrent[0], b) == concurrent_payload, "Flag-off broke prior canonical reads")
            result["flag_off"] = "new uploads separate; prior shared media readable; quarantine enforced"
        finally:
            compose(path, ["up", "-d", "--force-recreate", "synapse", "synapse-sync-worker", "gateway-worker", "gateway-baseline"], {"CAPACITY_MEDIA_DEDUP": "true"})
            wait_ready(api, info)
    write_json(path / "media-result.json", result)
    return result


def run_load(path: Path, route: str, vus: int, mode: str, hold: str, ramp: str, fixtures: Path | None) -> dict:
    path, info = load_run(path)
    if route not in {"worker", "baseline"} or mode not in {"sync", "transport"} or not 1 <= vus <= 500:
        raise ValueError("Invalid load scenario")
    api = LocalApi(info["base_url"] if route == "worker" else info["baseline_url"])
    probe(api, info)
    accounts = json.loads((path / "accounts.json").read_text(encoding="utf-8"))
    if len(accounts) < vus:
        raise ValueError("Not enough distinct accounts; bootstrap a larger new run")
    if mode == "transport" and fixtures is None:
        raise ValueError("Transport mode requires supplied encrypted event fixtures")
    # Make the membership workload comparable across baseline/worker repeats.
    # Only the dedicated synthetic membership room is left; main-room state stays.
    for account in accounts[:vus]:
        if account.get("join_room_id"):
            joined = api.request("GET", "/_matrix/client/v3/joined_rooms", account["access_token"])
            if account["join_room_id"] in joined.get("joined_rooms", []):
                api.request("POST", f"/_matrix/client/v3/rooms/{quote(account['join_room_id'], safe='')}/leave",
                            account["access_token"], {})
    load_id = "load-" + secrets.token_hex(12)
    label = f"{route}-{mode}-{vus}-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + load_id
    output = path / label
    output.mkdir()
    overrides = {"CAPACITY_BASE_URL": f"http://gateway-{route}:8080", "CAPACITY_VUS": str(vus), "CAPACITY_LOAD_ID": load_id,
        "CAPACITY_MODE": mode, "CAPACITY_HOLD": hold, "CAPACITY_RAMP": ramp,
        "CAPACITY_SUMMARY_FILE": f"/artifacts/{label}/summary.json"}
    if fixtures is not None:
        supplied = json.loads(fixtures.read_text(encoding="utf-8"))
        write_json(output / "encrypted-events.json", supplied)
        overrides["CAPACITY_EVENTS_FILE"] = f"/artifacts/{label}/encrypted-events.json"
    stop = threading.Event()

    def monitor():
        with (output / "resources.jsonl").open("w", encoding="utf-8") as stream:
            while not stop.is_set():
                try:
                    rows = compose(path, ["ps", "-q"], capture=True).stdout.split()
                    if rows:
                        sampled = local_docker(["stats", "--no-stream", "--format", "{{json .}}", *rows], capture=True)
                        for line in sampled.stdout.splitlines():
                            stream.write(json.dumps({"at": datetime.now(timezone.utc).isoformat(), "sample": json.loads(line)}) + "\n")
                        stream.flush()
                except (subprocess.SubprocessError, ValueError):
                    stream.write(json.dumps({"at": datetime.now(timezone.utc).isoformat(), "error": "resource sample unavailable"}) + "\n")
                stop.wait(5)

    sampler = threading.Thread(target=monitor, daemon=True)
    sampler.start()
    result = {"run_id": info["run_id"], "load_id": load_id, "route": route, "vus": vus, "mode": mode, "status": "failed"}
    try:
        compose(path, ["--profile", "load", "run", "--rm", "k6"], overrides)
        result["status"] = "k6 thresholds passed; inspect unobserved events and resources"
    finally:
        stop.set()
        sampler.join(timeout=15)
        write_json(output / "run-result.json", result)
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "up", "bootstrap", "media", "run", "down", "status"])
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--accounts", type=int, default=2)
    parser.add_argument("--vus", type=int, default=2)
    parser.add_argument("--route", choices=["worker", "baseline"], default="worker")
    parser.add_argument("--mode", choices=["sync", "transport"], default="sync")
    parser.add_argument("--hold", default="2m")
    parser.add_argument("--ramp", default="30s")
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--flag-off", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            result = prepare(args.run_dir)
        elif args.command == "up":
            path, info = load_run(args.run_dir)
            compose(path, ["up", "-d", "--build", "gateway-worker", "gateway-baseline"])
            wait_ready(LocalApi(info["base_url"]), info)
            result = {"ready": True, "run_id": info["run_id"]}
        elif args.command == "bootstrap":
            result = bootstrap(args.run_dir, args.accounts)
        elif args.command == "media":
            result = media_check(args.run_dir, args.flag_off)
        elif args.command == "run":
            result = run_load(args.run_dir, args.route, args.vus, args.mode, args.hold, args.ramp, args.fixtures)
        elif args.command == "down":
            compose(args.run_dir, ["down"])
            result = {"stopped": True, "data_retained": True}
        else:
            compose(args.run_dir, ["ps"])
            result = {"scope": "isolated project only"}
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, RuntimeError, AssertionError, OSError, subprocess.SubprocessError) as error:
        # Avoid exception reprs from network/subprocess objects: they may carry bodies.
        print(json.dumps({"status": "failed", "reason": str(error) if isinstance(error, (ValueError, RuntimeError, AssertionError))
                          else type(error).__name__, "scope": "no capacity claim"}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
