"""Worker topology and real template rendering contract, with isolated outputs."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import yaml

ROOT = Path(__file__).resolve().parents[2]


def load_template(name):
    spec = importlib.util.spec_from_file_location("worker_renderer", ROOT / "infra/render_config.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    values = module.parse_env(ROOT / ".env.example")
    return yaml.safe_load(module.render((ROOT / name).read_text(encoding="utf-8"), values))


def test_main_enables_replication_without_changing_key_rotation():
    main = load_template("infra/synapse/homeserver.yaml.template")
    assert main.get("redis") == {"enabled": True, "host": "matrix-redis", "port": 6379}
    assert main["presence"]["enabled"] is False
    assert any(item["port"] == 9093 and item["resources"] == [{"names": ["replication"]}]
               for item in main["listeners"])
    assert main["database"]["args"]["cp_max"] == 30
    assert main["rc_invites"]["per_room"] == {"per_second": 50, "burst_count": 1200}
    assert "encryption" not in main


def test_worker_has_own_listener_pool_and_main_destination():
    worker = load_template("infra/synapse/worker-sync.yaml.template")
    assert worker["worker_app"] == "synapse.app.generic_worker"
    assert worker.get("instance_map", {}).get("main") == {"host": "synapse", "port": 9093}
    assert not any(key.startswith("worker_replication_") for key in worker)
    assert worker["worker_listeners"][0]["port"] == 8081
    assert worker["database"]["args"]["cp_max"] == 15
    assert worker["worker_pid_file"] != "/data/homeserver.pid"


def test_compose_topology_and_proxy_routes():
    services = yaml.safe_load((ROOT / "docker-compose.yml").read_text(encoding="utf-8"))["services"]
    assert services["postgres"]["command"] == ["postgres", "-N", "250"]
    assert services["matrix-redis"]["image"] == "redis:7.4.2-alpine"
    worker = services["synapse-sync-worker"]
    assert worker["image"] == services["synapse"]["image"]
    assert "127.0.0.1:${SYNAPSE_SYNC_HTTP_PORT:-18081}:8081" in worker["ports"]
    assert "matrix-redis" in worker["depends_on"]
    assert "/data/worker-sync.yaml" in worker["command"]
    proxy = (ROOT / "infra/nginx/nginx.conf.template").read_text(encoding="utf-8")
    assert "server synapse-sync-worker:8081 resolve;" in proxy
    assert "^/_matrix/client/(r0|v3)/(?<" not in proxy
    assert "^/_matrix/client/(r0|v3)/(sync|events)$" in proxy
    assert "proxy_pass http://synapse_sync_upstream;" in proxy


def test_worker_is_rendered_and_drift_checked(tmp_path):
    # Use the real production renderer and templates, never the running data/.
    import shutil
    for folder in ("synapse", "nginx", "element", "sygnal"):
        shutil.copytree(ROOT / "infra" / folder, tmp_path / "infra" / folder)
    args = [sys.executable, str(ROOT / "infra/render_config.py"), "--root", str(tmp_path),
            "--env", str(ROOT / ".env.example")]
    result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    target = tmp_path / "data/synapse/worker-sync.yaml"
    assert target.exists(), "worker must be registered in rendered_targets"
    assert subprocess.run(args + ["--check"], capture_output=True).returncode == 0
    target.write_text("drift\n", encoding="utf-8")
    result = subprocess.run(args + ["--check"], capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 1
    assert "worker-sync.yaml" in result.stdout


def test_default_compose_has_no_colliding_published_ports():
    result = subprocess.run(["docker", "compose", "--env-file", str(ROOT / ".env.example"),
                             "-f", str(ROOT / "docker-compose.yml"), "config", "--format", "json"],
                            capture_output=True, text=True, encoding="utf-8", check=True)
    services = json.loads(result.stdout)["services"]
    published = {}
    for name, service in services.items():
        for port in service.get("ports", []):
            key = (port.get("published"), port.get("protocol", "tcp"))
            if key[0] is not None:
                assert key not in published, f"{name} conflicts with {published.get(key)} at {key}"
                published[key] = name
