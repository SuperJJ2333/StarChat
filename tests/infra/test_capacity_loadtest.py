"""Executable safety/config/state-machine contracts; no live services required."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from urllib.parse import unquote, urlsplit

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts/loadtest"
ARTIFACTS = ROOT / "docs/verification/artifacts/2026-09-09/media-dedup-implementation/capacity-tests"


def test_only_gateways_have_host_ingress_network():
    config = yaml.safe_load((SCRIPTS / "compose.isolated.yml").read_text(encoding="utf-8"))
    assert config["networks"]["isolated"]["internal"] is True
    assert config["networks"].get("ingress", {}).get("internal") is False
    for name, service in config["services"].items():
        expected = {"isolated", "ingress"} if name.startswith("gateway-") else {"isolated"}
        assert set(service["networks"]) == expected


def module():
    spec = importlib.util.spec_from_file_location("capacity_runner", SCRIPTS / "capacity.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


@pytest.fixture
def run_dir():
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="case-", dir=ARTIFACTS) as value:
        yield Path(value) / "run"


def test_isolation_target_guard_rejects_production_and_credential_urls():
    runner = module()
    for value in ["https://liuhetong888.com", "http://127.0.0.1.evil.test:8008",
                  "http://admin:secret@localhost:8008", "http://127.0.0.1:8008/path",
                  "http://10.0.0.1:8008", "http://gateway-worker:8080"]:
        with pytest.raises(ValueError):
            runner.validate_origin(value)
    assert runner.validate_origin("http://127.0.0.1:18008") == "http://127.0.0.1:18008"


@pytest.mark.parametrize("source", ["host", "context", "current"])
def test_remote_docker_is_rejected_before_compose(run_dir, monkeypatch, source):
    runner = module()
    runner.prepare(run_dir)
    monkeypatch.delenv("DOCKER_HOST", raising=False)
    monkeypatch.delenv("DOCKER_CONTEXT", raising=False)
    if source == "host":
        monkeypatch.setenv("DOCKER_HOST", "tcp://127.0.0.1:2375")
    if source == "context":
        monkeypatch.setenv("DOCKER_CONTEXT", "remote-test")
        monkeypatch.setenv("DOCKER_HOST", "unix:///var/run/docker.sock")
    calls = []

    def fake_run(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, json.dumps([
            {"Endpoints": {"docker": {"Host": "ssh://remote-test"}}}]), "")

    monkeypatch.setattr(runner.subprocess, "run", fake_run)
    with pytest.raises(ValueError, match="local Docker endpoint"):
        runner.compose(run_dir, ["up", "-d"])
    assert all(command[1:3] == ["context", "inspect"] for command in calls)


@pytest.mark.parametrize("endpoint", ["unix:///var/run/docker.sock", "npipe:////./pipe/dockerDesktopLinuxEngine"])
def test_local_docker_endpoint_is_explicit_for_compose_and_stats(run_dir, monkeypatch, endpoint):
    runner = module()
    runner.prepare(run_dir)
    monkeypatch.setenv("DOCKER_CONTEXT", "local-test")
    monkeypatch.setenv("DOCKER_HOST", "ssh://ignored-by-context")
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        if command[1:3] == ["context", "inspect"]:
            return subprocess.CompletedProcess(command, 0, json.dumps([
                {"Endpoints": {"docker": {"Host": endpoint}}}]), "")
        assert command[1:3] == ["--host", endpoint]
        assert "DOCKER_CONTEXT" not in kwargs["env"]
        assert "DOCKER_HOST" not in kwargs["env"]
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(runner.subprocess, "run", fake_run)
    runner.compose(run_dir, ["config", "--quiet"])
    runner.local_docker(["stats", "--no-stream"], capture=True)
    assert [item[0][3] for item in calls if item[0][1] == "--host"] == ["compose", "stats"]


def test_local_docker_daemon_failure_is_not_swallowed(monkeypatch):
    runner = module()
    monkeypatch.delenv("DOCKER_CONTEXT", raising=False)
    monkeypatch.setenv("DOCKER_HOST", "unix:///var/run/docker.sock")
    failure = subprocess.CalledProcessError(1, ["docker"], stderr="local daemon unavailable")

    def unavailable(*_args, **_kwargs):
        raise failure

    monkeypatch.setattr(runner.subprocess, "run", unavailable)
    with pytest.raises(subprocess.CalledProcessError) as caught:
        runner.local_docker(["compose", "up", "-d"])
    assert caught.value is failure


def test_prepare_uses_only_artifact_paths_and_isolated_secrets(run_dir):
    runner = module()
    info = runner.prepare(run_dir)
    assert (run_dir / ".gitignore").read_text(encoding="utf-8") == "*\n!.gitignore\n"
    config = json.loads((run_dir / "synapse/homeserver.yaml").read_text(encoding="utf-8"))
    assert config["server_name"] == "capacity.localhost"
    assert config["presence"]["enabled"] is False
    assert config["database"]["args"]["cp_max"] == 30
    assert config["redis"]["host"] == "matrix-redis"
    assert config["registration_shared_secret"]
    worker = json.loads((run_dir / "synapse/worker-sync.yaml").read_text(encoding="utf-8"))
    assert worker["instance_map"] == {"main": {"host": "synapse", "port": 9093}}
    assert "worker_replication_host" not in worker
    assert "CAPACITY_ISOLATED_TEST" in (run_dir / "compose.env").read_text(encoding="utf-8")
    assert json.loads((run_dir / "isolation.json").read_text(encoding="utf-8"))["run_id"] == info["run_id"]
    with pytest.raises(ValueError):
        runner.prepare(ROOT / "data/capacity-unsafe")
    with pytest.raises(ValueError):
        runner.prepare(run_dir)
    text = (run_dir / "compose.env").read_text(encoding="utf-8")
    (run_dir / "compose.env").write_text(text.replace(run_dir.as_posix(), str(ROOT / "data")), encoding="utf-8")
    with pytest.raises(ValueError, match="no longer matches"):
        runner.load_run(run_dir)


def test_compose_is_pinned_local_and_does_not_mount_production_data():
    compose = yaml.safe_load((SCRIPTS / "compose.isolated.yml").read_text(encoding="utf-8"))
    services = compose["services"]
    assert services["k6"]["image"] == "grafana/k6:0.54.0"
    assert services["matrix-redis"]["image"] == "redis:7.4.2-alpine"
    assert services["synapse"]["image"] == services["synapse-sync-worker"]["image"]
    assert compose["networks"]["isolated"]["internal"] is True
    for service in services.values():
        assert ":latest" not in service.get("image", "")
        assert all(str(port).startswith("127.0.0.1:") for port in service.get("ports", []))
        assert all("./data" not in volume for volume in service.get("volumes", []))


def test_k6_core_real_guard_distinct_accounts_and_incremental_sync():
    script = """
      import assert from 'node:assert/strict';
      import {parseConfig, makeState, step} from CORE;
      const env = {CAPACITY_ISOLATED_TEST:'YES', CAPACITY_RUN_ID:'unit-run', CAPACITY_LOAD_ID:'unit-load', CAPACITY_BASE_URL:'http://127.0.0.1:18008', CAPACITY_VUS:'2'};
      const accounts=[{user_id:'@a:capacity.localhost',access_token:'fake-a',room_id:'!r:capacity.localhost',join_room_id:'!j:capacity.localhost'}, {user_id:'@b:capacity.localhost',access_token:'fake-b',room_id:'!r:capacity.localhost'}];
      for (const bad of ['https://example.com','http://127.0.0.1.evil.test','http://u:p@localhost','http://localhost/x']) {
        assert.throws(()=>parseConfig({...env,CAPACITY_BASE_URL:bad},accounts,[]));
      }
      assert.throws(()=>parseConfig({...env,CAPACITY_VUS:'501'},accounts,[]));
      assert.throws(()=>parseConfig(env,[accounts[0],accounts[0]],[]));
      assert.throws(()=>parseConfig({...env,CAPACITY_MODE:'transport'},accounts,[]));
      const config=parseConfig(env,accounts,[]);
      const requests=[];
      const api={request:(method,url,body,params)=>{
        requests.push({method,url,body,params});
        if(url.includes('/join/'))return {status:200,json:()=>({room_id:'!j:capacity.localhost'})};
        return {status:200,timings:{duration:requests.length===2?37:30000},json:()=>({next_batch:requests.length===2?'s+1':'s2',rooms:{join:{}}})};
      }};
      const state=makeState(); const recorded={}; const metrics={add:(name,value)=>{recorded[name]=value;}};
      step(config,accounts[0],state,api,metrics,1);
      step(config,accounts[0],state,api,metrics,1);
      assert.equal(requests.length,3);
      assert.equal(requests[0].method,'POST');
      assert.ok(requests[1].url.includes('timeout=0'));
      assert.ok(requests[2].url.includes('since=s%2B1'));
      assert.ok(requests[2].url.includes('timeout=30000'));
      assert.equal(requests[1].params.headers.Authorization,'Bearer fake-a');
      assert.equal(requests[1].params.redirects,0);
      assert.ok(requests.every(r=>!r.url.includes('fake-a')));
      assert.equal(state.since,'s2');
      assert.equal(recorded.sync_initial_duration,37);
      assert.equal(recorded.sync_incremental_duration,30000);
    """.replace("CORE", json.dumps((SCRIPTS / "capacity-core.js").as_uri()))
    result = subprocess.run(["node", "--input-type=module", "-e", script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_k6_core_transport_only_sends_supplied_encrypted_events():
    script = """
      import assert from 'node:assert/strict';
      import {parseConfig,makeState,step} from CORE;
      const user={user_id:'@a:capacity.localhost',access_token:'fake',room_id:'!r:capacity.localhost'};
      const env={CAPACITY_ISOLATED_TEST:'YES',CAPACITY_RUN_ID:'unit-run',CAPACITY_LOAD_ID:'unit-load',CAPACITY_BASE_URL:'http://127.0.0.1:18008',CAPACITY_VUS:'1',CAPACITY_MODE:'transport'};
      const fixture={user_id:user.user_id,room_id:user.room_id,content:{algorithm:'m.megolm.v1.aes-sha2',sender_key:'fake-public-key',device_id:'FAKE',session_id:'fake-session',ciphertext:'ZmFrZS1jaXBoZXJ0ZXh0'}};
      assert.throws(()=>parseConfig(env,[user],[{...fixture,content:{...fixture.content,body:'plaintext forbidden'}}]));
      const config=parseConfig(env,[user],[fixture]); const requests=[];
      const api={request:(method,url,body,params)=>{requests.push({method,url,body,params});return {status:200,json:()=>url.includes('/send/')?{event_id:'$sent'}:{next_batch:'s1',rooms:{join:{[user.room_id]:{timeline:{events:[{event_id:'$sent',type:'m.room.encrypted'}]}}}}}};}};
      const totals={}; const metrics={add:(key,value=1)=>{totals[key]=(totals[key]||0)+Number(value);}};
      step(config,user,makeState(),api,metrics,1);
      assert.ok(requests[0].url.includes('/send/m.room.encrypted/'));
      assert.deepEqual(JSON.parse(requests[0].body),fixture.content);
      assert.equal(totals.transport_events_received,1);
      assert.equal(totals.own_events_observed,1);
      assert.ok(requests.every(r=>!r.url.includes('/m.room.message/')));
    """.replace("CORE", json.dumps((SCRIPTS / "capacity-core.js").as_uri()))
    result = subprocess.run(["node", "--input-type=module", "-e", script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_k6_transactions_are_unique_between_loads_but_stable_on_retry():
    script = """
      import assert from 'node:assert/strict';
      import {parseConfig,makeState,step} from CORE;
      const user={user_id:'@a:capacity.localhost',access_token:'fake',room_id:'!r:capacity.localhost'};
      const env={CAPACITY_ISOLATED_TEST:'YES',CAPACITY_RUN_ID:'same-isolation',CAPACITY_BASE_URL:'http://127.0.0.1:18008',CAPACITY_VUS:'1',CAPACITY_MODE:'transport'};
      const fixture={user_id:user.user_id,room_id:user.room_id,content:{algorithm:'m.megolm.v1.aes-sha2',sender_key:'fake-public-key',device_id:'FAKE',session_id:'fake-session',ciphertext:'ZmFrZS1jaXBoZXJ0ZXh0'}};
      const urls=[];
      const api={request:(method,url)=>{
        if(method==='PUT'){urls.push(url);return {status:200,json:()=>({event_id:'$sent'})};}
        return {status:503,json:()=>({})};
      }};
      const sink={add:()=>{}};
      const baseline=parseConfig({...env,CAPACITY_LOAD_ID:'load-baseline'},[user],[fixture]);
      const baselineState=makeState();
      step(baseline,user,baselineState,api,sink,1);
      step(baseline,user,baselineState,api,sink,1);
      const worker=parseConfig({...env,CAPACITY_LOAD_ID:'load-worker'},[user],[fixture]);
      step(worker,user,makeState(),api,sink,1);
      assert.equal(urls[0],urls[1], 'retry within the same invocation must reuse its txid');
      assert.notEqual(urls[0],urls[2], 'baseline and worker invocations must send distinct transactions');
    """.replace("CORE", json.dumps((SCRIPTS / "capacity-core.js").as_uri()))
    result = subprocess.run(["node", "--input-type=module", "-e", script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_k6_successful_send_followed_by_sync_retry_counts_event_once():
    script = """
      import assert from 'node:assert/strict';
      import {parseConfig,makeState,step} from CORE;
      const user={user_id:'@a:capacity.localhost',access_token:'fake',room_id:'!r:capacity.localhost'};
      const env={CAPACITY_ISOLATED_TEST:'YES',CAPACITY_RUN_ID:'unit-run',CAPACITY_LOAD_ID:'unit-load',CAPACITY_BASE_URL:'http://127.0.0.1:18008',CAPACITY_VUS:'1',CAPACITY_MODE:'transport'};
      const fixture={user_id:user.user_id,room_id:user.room_id,content:{algorithm:'m.megolm.v1.aes-sha2',sender_key:'fake-public-key',device_id:'FAKE',session_id:'fake-session',ciphertext:'ZmFrZS1jaXBoZXJ0ZXh0'}};
      const config=parseConfig(env,[user],[fixture]);const totals={};let syncs=0;
      const api={request:(method)=>{
        if(method==='PUT') return {status:200,json:()=>({event_id:'$same'})};
        syncs++;
        if(syncs===1) return {status:503,json:()=>({})};
        const body={next_batch:'s1',rooms:{join:{[user.room_id]:{timeline:{events:[{event_id:'$same',type:'m.room.encrypted'}]}}}}};
        return {status:200,json:()=>body};
      }};
      const sink={add:(key,value=1)=>{totals[key]=(totals[key]||0)+Number(value);}};
      const state=makeState();step(config,user,state,api,sink,1);step(config,user,state,api,sink,1);
      assert.equal(totals.transport_events_sent,1);
      assert.equal(totals.own_events_observed,1);
      assert.equal(state.iteration,1);
    """.replace("CORE", json.dumps((SCRIPTS / "capacity-core.js").as_uri()))
    result = subprocess.run(["node", "--input-type=module", "-e", script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_runner_generates_distinct_load_ids_even_with_same_route_and_second(run_dir, monkeypatch):
    runner = module()
    isolation = runner.prepare(run_dir)
    runner.write_json(run_dir / "accounts.json", [{"user_id": "@a:capacity.localhost", "access_token": "fake"}])
    monkeypatch.setattr(runner, "probe", lambda *_args: None)

    class SameClock:
        @staticmethod
        def now(_tz):
            return type("Instant", (), {"strftime": lambda _self, _format: "20260910T000000Z"})()

    class NoSampler:
        def __init__(self, **_kwargs):
            pass

        def start(self):
            pass

        def join(self, **_kwargs):
            pass

    monkeypatch.setattr(runner, "datetime", SameClock)
    monkeypatch.setattr(runner.threading, "Thread", NoSampler)
    overrides = []
    monkeypatch.setattr(runner, "compose", lambda _path, _args, values: overrides.append(values))
    first = runner.run_load(run_dir, "worker", 1, "sync", "1s", "1s", None)
    second = runner.run_load(run_dir, "worker", 1, "sync", "1s", "1s", None)
    assert first["run_id"] == second["run_id"] == isolation["run_id"]
    assert first["load_id"] != second["load_id"]
    assert [item["CAPACITY_LOAD_ID"] for item in overrides] == [first["load_id"], second["load_id"]]
    assert len(list(run_dir.glob("worker-sync-1-*/run-result.json"))) == 2


def test_python_http_refuses_redirect_and_probe_never_sends_credentials():
    runner = module()
    received = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            received.append((self.path, self.headers.get("Authorization")))
            self.send_response(302)
            self.send_header("Location", "https://example.com/production")
            self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with pytest.raises(RuntimeError, match="HTTP 302"):
            runner.probe(runner.LocalApi(f"http://127.0.0.1:{server.server_port}"), {"run_id": "fake"})
        assert received == [("/_capacity/identity", None)]
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_bootstrap_http_rate_limit_backoff_is_bounded_and_opt_in(monkeypatch):
    runner = module()
    calls = []
    waits = []
    monkeypatch.setattr(runner.time, "sleep", waits.append)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            calls.append(self.path)
            # Drain the request before closing the test connection: on Windows
            # unread POST data can reset the socket before the response is read.
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            retry = self.path != "/retry" or calls.count("/retry") <= 2
            payload = json.dumps({"errcode": "M_LIMIT_EXCEEDED", "retry_after_ms": 10} if retry else {"joined": True}).encode()
            self.send_response(429 if retry else 200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        api = runner.LocalApi(f"http://127.0.0.1:{server.server_port}")
        assert api.request("POST", "/retry", body={}, retry_rate_limit=True) == {"joined": True}
        assert waits == [0.01, 0.01]
        assert api.rate_limit_retries == 2
        with pytest.raises(RuntimeError, match="HTTP 429"):
            api.request("POST", "/measured-operation", body={})
        assert len(waits) == 2, "Measured requests must not silently retry admission limits"
        with pytest.raises(RuntimeError, match="rate-limit retry budget"):
            api.request("POST", "/always-limited", body={}, retry_rate_limit=True)
        assert calls.count("/always-limited") <= 13
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def test_media_runner_exercises_http_lifecycle_and_flag_off_without_logging_tokens(run_dir, monkeypatch, capsys):
    """Transport emulator validates the runner, NOT the real Synapse patch."""
    runner = module()
    info = runner.prepare(run_dir)
    accounts = [{"user_id": "@a:capacity.localhost", "access_token": "fake-a"},
                {"user_id": "@b:capacity.localhost", "access_token": "fake-b"}]
    runner.write_json(run_dir / "accounts.json", accounts)
    runner.write_json(run_dir / "admin.json", {"access_token": "fake-admin"})
    state = {"dedup": True, "blobs": {}, "refs": {}, "quarantined": set(), "uploads": 0}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def handle_request(self):
            with lock:
                path = unquote(urlsplit(self.path).path)
                token = self.headers.get("Authorization", "").removeprefix("Bearer ")
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                code, result = 200, {}
                if path == "/_capacity/identity":
                    result = {"run_id": info["run_id"], "server_name": "capacity.localhost"}
                elif path == "/_matrix/client/versions":
                    result = {"versions": ["v1.11"]}
                elif path == "/_matrix/media/v3/upload":
                    state["uploads"] += 1
                    matches = [key for key, value in state["blobs"].items() if value == body]
                    if any(key in state["quarantined"] for key in matches):
                        code, result = 403, {"errcode": "M_FORBIDDEN"}
                    else:
                        media = matches[0] if state["dedup"] and matches else f"media{state['uploads']}"
                        state["blobs"][media] = body
                        state["refs"].setdefault(token, set()).add(media)
                        result = {"content_uri": "mxc://capacity.localhost/" + media}
                elif path.startswith("/_matrix/client/v1/media/download/"):
                    result = state["blobs"][path.rsplit("/", 1)[1]]
                elif path.startswith("/_synapse/admin/v1/users/"):
                    assert token == "fake-admin"
                    user = "fake-a" if "@a:" in path else "fake-b"
                    if self.command == "DELETE":
                        state["refs"][user] = set()
                    result = {"media": [{"media_id": key} for key in state["refs"].get(user, set())]}
                elif path.startswith("/_synapse/admin/v1/media/quarantine/"):
                    assert token == "fake-admin"
                    state["quarantined"].add(path.rsplit("/", 1)[1])
                else:
                    code = 404
                payload = result if isinstance(result, bytes) else json.dumps(result).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        do_GET = do_POST = do_DELETE = handle_request

    def restart(_path, _args, overrides):
        state["dedup"] = overrides["CAPACITY_MEDIA_DEDUP"] == "true"

    monkeypatch.setattr(runner, "compose", restart)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    info["base_url"] = f"http://127.0.0.1:{server.server_port}"
    runner.write_json(run_dir / "isolation.json", info)
    try:
        result = runner.media_check(run_dir, flag_off=True)
        assert result["same_mxc_cross_user"] is True
        assert result["concurrent_uploads"] == 8
        assert "prior shared media readable" in result["flag_off"]
        assert state["dedup"] is True
        assert "fake-a" not in (run_dir / "media-result.json").read_text(encoding="utf-8")
        assert "fake-admin" not in capsys.readouterr().out
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
