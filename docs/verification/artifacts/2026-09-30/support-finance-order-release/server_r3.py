"""Server-side operator commands for a frozen 0092 wallet workspace package.

Use only after review and package freeze. This module is never imported by the
application. It refuses to run outside its dedicated /opt/starchat release dir.
"""

from __future__ import annotations

import argparse
import copy
from contextlib import ExitStack
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import time
from uuid import uuid4

from release import (
    BASE_SCHEMA,
    TARGET_SCHEMA,
    FRONTEND,
    GUARD,
    PROBE,
    IMAGE_ROOTS,
    MANIFEST,
    PACKAGE,
    PG,
    RELEASE_ID,
    ROLE_CONTAINER,
    ROLE_SERVICE,
    _atomic_replace,
    assert_exact_inventory_delta,
    compose_with_image,
    restore_static_file,
    services_to_switch,
    sha_file,
    utc,
    validate_manifest,
)
from release import _image


RELEASE_ROOT = Path("/opt/starchat/releases") / RELEASE_ID
PRIVATE = RELEASE_ROOT / "private"
# Read-only host inventory on 2026-09-28 resolved postgres:16.9-alpine to this immutable ID.
CLONE_IMAGE = "sha256:7c688148e5e156d0e86df7ba8ae5a05a2386aaec1e2ad8e6d11bdf10504b1fb7"
CLONE_DSN = "postgresql+psycopg://postgres@127.0.0.1:5432/clone"
PGOPTIONS = "-c lock_timeout=5000 -c statement_timeout=60000"
WALLET_PROBE_CASES = frozenset({
    "unique_preview_resolves_nonzero",
    "multiple_preview_requires_selection",
    "missing_preview_rejects_transfer",
    "revoked_grant_blocks_proof",
    "revoked_owner_blocks_proof",
    "execute_requires_exact_index",
})
POST_SWITCH_LOG_TAIL = 200
POST_SWITCH_LOG_MAX_BYTES = 1_000_000
INVENTORY_CODE = (
    "import hashlib,json,pathlib,sys;"
    "roots=json.loads(sys.argv[1]);"
    "files=(p for root in roots for p in pathlib.Path(root).rglob('*.py') if p.is_file());"
    "print(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}))"
)
STRUCTURE_SQL = (
    "select (select count(*) from information_schema.tables "
    "where table_schema='public' and table_type='BASE TABLE')::text || ':' || "
    "(select count(*) from pg_constraint c join pg_namespace n on n.oid=c.connamespace "
    "where n.nspname='public')::text"
)


def _clone_name(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", value):
        raise ValueError("invalid isolated clone name")
    return value


def _remove_clone_with_volumes(clone: str, inspected: dict | None = None) -> dict:
    """Remove the isolated PostgreSQL container and prove its data volume is gone."""
    clone = _clone_name(clone)
    snapshot = inspected if inspected is not None else docker_inspect(clone)
    if snapshot.get("Name") != "/" + clone or snapshot.get("HostConfig", {}).get("Binds"):
        raise ValueError("isolated clone identity or bind mounts changed before cleanup")
    mounts = snapshot.get("Mounts", [])
    volumes = [mount.get("Name") for mount in mounts if mount.get("Type") == "volume"]
    if (not volumes or any(not isinstance(name, str) or not name for name in volumes)
            or not any(mount.get("Type") == "volume" and
                       mount.get("Destination") == "/var/lib/postgresql/data" for mount in mounts)):
        raise ValueError("isolated clone anonymous PostgreSQL volume could not be identified")
    run("docker", "rm", "-f", "-v", clone)
    if clone in run("docker", "container", "ls", "-a", "--format", "{{.Names}}").splitlines():
        raise ValueError("isolated clone still exists after removal")
    present = set(run("docker", "volume", "ls", "--format", "{{.Name}}").splitlines())
    if present.intersection(volumes):
        raise ValueError("isolated clone anonymous volume still exists after removal")
    return {"clone_removed": True, "clone_volume_removed": True,
            "clone_volume_names": volumes}


def _clone_runner(image: str, clone: str) -> list[str]:
    _image(image)
    return [
        "docker", "run", "--rm", "--pull", "never",
        "--network", "container:" + _clone_name(clone),
        "--read-only", "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--memory", "1g", "--cpus", "2", "--pids-limit", "256",
        "--tmpfs", "/tmp:rw,nosuid,size=128m",
        "--workdir", "/opt/business-api",
        "-e", "PYTHONDONTWRITEBYTECODE=1",
        "-e", "BUSINESS_ENVIRONMENT=test",
        "-e", "BUSINESS_DATABASE_URL=" + CLONE_DSN,
        "-e", "PGOPTIONS=" + PGOPTIONS,
    ]


def clone_startup_command(image: str, clone: str) -> list[str]:
    ready_probe = (
        "from fastapi.testclient import TestClient\n"
        "from app.main import create_default_app\n"
        "app = create_default_app()\n"
        "with TestClient(app) as client:\n"
        "    response = client.get('/api/v1/health/ready')\n"
        "    assert response.status_code == 200\n"
        "    body = response.json()\n"
        "    assert body.get('ok') is True\n"
        "    assert body.get('database') == 'ready'\n"
    )
    startup = "python -c " + shlex.quote(ready_probe)
    return [*_clone_runner(image, clone), "--entrypoint", "sh", image, "-c", startup]


def wait_clone_database(clone: str) -> None:
    """Wait for the final TCP server to accept SQL in the intended database."""
    command = ["docker", "exec", _clone_name(clone), "psql", "-X", "-v", "ON_ERROR_STOP=1",
               "-h", "127.0.0.1", "-U", "postgres", "-d", "clone",
               "-Atqc", "SELECT current_database()"]
    deadline = time.monotonic() + 60
    for attempt in range(60):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=min(1, remaining))
        except subprocess.TimeoutExpired:
            result = None
        if result is not None and result.returncode == 0 and result.stdout.strip() == "clone":
            return
        if attempt < 59:
            time.sleep(min(1, max(0, deadline - time.monotonic())))
    raise RuntimeError("isolated clone TCP SQL readiness timed out before PostgreSQL restore")


def assert_production_0092(shape: dict) -> None:
    if (shape.get("schema") != TARGET_SCHEMA or
            shape.get("column") != "YES:character varying:16"):
        raise ValueError("0092 production schema/column mismatch")
    check = shape.get("check")
    if (not isinstance(check, str) or
            not all(part in check for part in ("entry_mode", "STAFF", "ADMIN"))):
        raise ValueError("0092 production entry mode constraint mismatch")


def run(*args: str, input_file: Path | None = None, output_file: Path | None = None,
        timeout: int = 600) -> str:
    with ExitStack() as stack:
        source = stack.enter_context(input_file.open("rb") if input_file else open(os.devnull, "rb"))
        target = stack.enter_context(output_file.open("wb")) if output_file else subprocess.PIPE
        proc = subprocess.run(args, stdin=source, stdout=target,
                              stderr=subprocess.PIPE, timeout=timeout)
    if proc.returncode:
        if PRIVATE.is_dir() and proc.stderr:
            (PRIVATE / "last-command.stderr.private.log").write_bytes(proc.stderr)
        raise RuntimeError(f"command failed (exit {proc.returncode}): {args[0]} {args[1] if len(args)>1 else ''}")
    if proc.stderr and output_file is not None:
        (PRIVATE / "last-command.stderr.private.log").write_bytes(proc.stderr)
    return proc.stdout.decode("utf-8").strip() if output_file is None else ""


def write_private(name: str, value: object) -> Path:
    path = PRIVATE / name
    if path.exists():
        raise ValueError(f"existing private file: {name}")
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")
    os.chmod(path, 0o600)
    return path


def read_private(name: str) -> dict:
    return json.loads((PRIVATE / name).read_text(encoding="utf-8"))


def docker_inspect(name: str) -> dict:
    return json.loads(run("docker", "inspect", name))[0]


def running_containers() -> dict[str, dict]:
    ids = run("docker", "ps", "-q").splitlines()
    result = {}
    for container_id in ids:
        item = docker_inspect(container_id)
        result[item["Name"]] = {
            "id": item["Id"], "image": item["Image"],
            "started": item["State"]["StartedAt"],
        }
    return result


def assert_single_api_ingress() -> None:
    expected = docker_inspect(ROLE_CONTAINER["api"])["Id"]
    selected = run(
        "docker", "ps", "--no-trunc", "-q",
        "--filter", "label=com.docker.compose.project=starchat",
        "--filter", "label=com.docker.compose.service=business-api",
    ).splitlines()
    if selected != [expected]:
        raise ValueError("management login freeze requires the sole API Compose replica")


def assert_managed_api_ingress() -> bool:
    """Return whether the one managed API runs; permit its already-exited state."""
    container = docker_inspect(ROLE_CONTAINER["api"])
    selected = run(
        "docker", "ps", "--no-trunc", "-q",
        "--filter", "label=com.docker.compose.project=starchat",
        "--filter", "label=com.docker.compose.service=business-api",
    ).splitlines()
    if selected == [container["Id"]] and container["State"]["Running"] is True:
        return True
    if not selected and container["State"]["Running"] is False:
        return False
    raise ValueError("unexpected API ingress replica or running state blocks rollback")


def database_value(query: str) -> str:
    # Credentials remain inside the PostgreSQL container and are never printed.
    script = 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc ' + json.dumps(query)
    return run("docker", "exec", PG, "sh", "-c", script)


def production_schema_shape() -> dict:
    return {
        "schema": database_value("select version_num from alembic_version"),
        "column": database_value(
            "select is_nullable || ':' || data_type || ':' || "
            "character_maximum_length::text from information_schema.columns "
            "where table_schema='public' and table_name='identity_admin_sessions' "
            "and column_name='entry_mode'",
        ),
        "check": database_value(
            "select pg_get_constraintdef(oid) from pg_constraint "
            "where conrelid='identity_admin_sessions'::regclass "
            "and conname='ck_identity_admin_sessions_entry_mode' and contype='c'",
        ),
    }


def clone_database_value(clone: str, query: str) -> str:
    return run("docker", "exec", _clone_name(clone), "psql", "-X", "-v",
               "ON_ERROR_STOP=1", "-U", "postgres", "-d", "clone", "-Atc", query)


def clone_snapshot(clone: str, *, after: bool) -> dict:
    structure = clone_database_value(clone, STRUCTURE_SQL).split(":")
    if len(structure) != 2 or not all(value.isdecimal() for value in structure):
        raise ValueError("invalid isolated clone structure result")
    state = {
        "schema": clone_database_value(clone, "select version_num from alembic_version"),
        "tables": int(structure[0]),
        "constraints": int(structure[1]),
        "admin_sessions": int(clone_database_value(
            clone, "select count(*) from identity_admin_sessions")),
    }
    if after:
        state["null_entry_modes"] = int(clone_database_value(
            clone, "select count(*) from identity_admin_sessions where entry_mode is null"))
        state["column"] = clone_database_value(
            clone,
            "select is_nullable || ':' || data_type || ':' || "
            "character_maximum_length::text from information_schema.columns "
            "where table_schema='public' and table_name='identity_admin_sessions' "
            "and column_name='entry_mode'",
        )
        state["check"] = clone_database_value(
            clone,
            "select pg_get_constraintdef(oid) from pg_constraint "
            "where conrelid='identity_admin_sessions'::regclass "
            "and conname='ck_identity_admin_sessions_entry_mode' and contype='c'",
        )
    return state


def clone_compatibility_proof() -> dict:
    try:
        proof = read_private("clone-compatibility.json")
    except FileNotFoundError as error:
        raise ValueError("0092 clone compatibility proof is required") from error
    if (proof.get("after", {}).get("schema") != TARGET_SCHEMA or
            proof.get("candidate_started") is not True or
            proof.get("rollback_started") is not True or
            proof.get("before") != proof.get("after")):
        raise ValueError("0092 clone compatibility proof incomplete")
    return proof


def probe_clone(manifest: dict) -> dict:
    restored = read_private("restore-running.json")
    check_prepared(manifest, isolated_clone=restored)
    images = read_private("images.json")
    rollback_images = read_private("rollback-images.json")
    if (restored.get("candidate_images") != images or
            restored.get("rollback_images") != rollback_images):
        raise ValueError("clone image identity changed")
    inspected = docker_inspect(restored["clone"])
    if (inspected["Id"] != restored["clone_id"] or
            inspected["HostConfig"]["NetworkMode"] != "none" or
            inspected["State"]["Running"] is not True):
        raise ValueError("isolated clone identity/network changed")
    if (PRIVATE / "clone-compatibility.json").exists():
        raise ValueError("clone compatibility already attempted")
    run(*clone_startup_command(images["api"], restored["clone"]),
        output_file=PRIVATE / "candidate-startup.private.log", timeout=180)
    run(*clone_startup_command(rollback_images["api"], restored["clone"]),
        output_file=PRIVATE / "rollback-startup.private.log", timeout=180)
    after = clone_snapshot(restored["clone"], after=True)
    if after != restored["before"]:
        raise ValueError("same-schema candidate/rollback startup changed isolated clone")
    proof = {
        "probed_utc": utc(), "clone_id": restored["clone_id"],
        "candidate_api_image": images["api"],
        "rollback_api_image": rollback_images["api"],
        "before": restored["before"], "after": after,
        "candidate_started": True, "rollback_started": True,
    }
    write_private("clone-compatibility.json", proof)
    return {"clone_schema": TARGET_SCHEMA, "candidate_and_rollback_started": True}


def image_inventory(image: str, role: str) -> dict[str, str]:
    result = run("docker", "run", "--rm", "--network", "none", "--read-only",
                 "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                 "--memory", "768m", "--cpus", "2", "-e", "PYTHONDONTWRITEBYTECODE=1",
                 "--entrypoint", "python", image, "-c", INVENTORY_CODE,
                 json.dumps(IMAGE_ROOTS[role]), timeout=180)
    return json.loads(result)


def container_inventory(container: str, role: str) -> dict[str, str]:
    return json.loads(run("docker", "exec", "-e", "PYTHONDONTWRITEBYTECODE=1",
                          container, "python", "-c", INVENTORY_CODE,
                          json.dumps(IMAGE_ROOTS[role]), timeout=180))


def live_hash(container: str, dest: str) -> str | None:
    probe = subprocess.run(["docker", "exec", container, "test", "-f", dest],
                           capture_output=True, timeout=30)
    if probe.returncode == 1:
        return None
    if probe.returncode:
        raise RuntimeError("live target probe failed")
    return run("docker", "exec", container, "sha256sum", dest).split()[0]


def compose_input(container: dict, role: str, expected_sha: str) -> tuple[Path, dict]:
    labels = container["Config"]["Labels"]
    if labels.get("com.docker.compose.project") != "starchat" or labels.get("com.docker.compose.service") != ROLE_SERVICE[role]:
        raise ValueError("container is outside expected Compose project/service")
    files = labels["com.docker.compose.project.config_files"].split(",")
    if len(files) != 1:
        raise ValueError("unexpected Compose layer count; manual rebase required")
    path = Path(files[0])
    if sha_file(path) != expected_sha:
        raise ValueError("Compose source SHA drift")
    config = json.loads(run("docker", "compose", "-p", "starchat", "-f", str(path),
                            "config", "--format", "json"))
    service = ROLE_SERVICE[role]
    services = set(config.get("services", {}))
    if service not in services or services not in ({service}, set(ROLE_SERVICE.values())):
        raise ValueError("Compose actual service set mismatch")
    for checked_role, checked_service in ROLE_SERVICE.items():
        if checked_service not in services:
            continue
        actual = container if checked_role == role else docker_inspect(ROLE_CONTAINER[checked_role])
        actual_labels = actual["Config"]["Labels"]
        if (actual_labels.get("com.docker.compose.project") != "starchat" or
                actual_labels.get("com.docker.compose.service") != checked_service or
                config["services"][checked_service]["image"] != actual["Image"]):
            raise ValueError(f"Compose {checked_service} image/project mismatch")
        runtime_env = dict(item.split("=", 1) for item in actual["Config"]["Env"] if "=" in item)
        if any((key in runtime_env if value is None else runtime_env.get(key) != str(value))
               for key, value in config["services"][checked_service].get("environment", {}).items()):
            raise ValueError(f"running environment differs from Compose for {checked_service}")
    return path, config


def assert_source_compose_consistency(configs: dict) -> None:
    if set(configs) != {"api", "worker"}:
        raise ValueError("both Compose role sources are required")
    for role, config in configs.items():
        services = config["rendered"]["services"]
        if set(services) not in ({ROLE_SERVICE[role]}, set(ROLE_SERVICE.values())):
            raise ValueError("unexpected Compose source services")
        peer = "worker" if role == "api" else "api"
        peer_service = ROLE_SERVICE[peer]
        if (peer_service in services and
                services[peer_service] != configs[peer]["rendered"]["services"][peer_service]):
            raise ValueError("Compose peer service differs across frozen sources")


def render_merged_baseline(manifest: dict, configs: dict) -> dict:
    assert_source_compose_consistency(configs)
    command = ["docker", "compose", "-p", "starchat"]
    for role in ("api", "worker"):
        command += ["-f", configs[role]["original_path"]]
    merged = json.loads(run(*command, "config", "--format", "json"))
    if set(merged.get("services", {})) != set(ROLE_SERVICE.values()):
        raise ValueError("merged baseline Compose roles changed")
    for role, service in ROLE_SERVICE.items():
        if merged["services"][service].get("image") != manifest["roles"][role]["base_image"]:
            raise ValueError("merged baseline Compose image mismatch")
        runtime = docker_inspect(ROLE_CONTAINER[role])
        runtime_env = dict(item.split("=", 1) for item in runtime["Config"]["Env"] if "=" in item)
        if any((key in runtime_env if value is None else runtime_env.get(key) != str(value))
               for key, value in merged["services"][service].get("environment", {}).items()):
            raise ValueError("merged baseline Compose environment mismatch")
    return merged


def package_payload(manifest: dict) -> None:
    for role, record in manifest["roles"].items():
        for item in record["files"]:
            path = PACKAGE / "payload" / item["source"]
            if path.is_symlink() or not path.is_file() or sha_file(path) != item["after_sha256"]:
                raise ValueError(f"package payload mismatch: {role}/{item['source']}")
    for item in manifest["static"]:
        path = PACKAGE / "payload" / item["source"]
        if path.is_symlink() or not path.is_file() or sha_file(path) != item["after_sha256"]:
            raise ValueError(f"package static mismatch: {item['source']}")


def check_guard_sources(manifest: dict) -> None:
    if sha_file(GUARD) != manifest["guard_sha256"]:
        raise ValueError("refresh protocol guard changed")
    if sha_file(PROBE) != manifest["guard_probe_sha256"]:
        raise ValueError("refresh protocol probe changed")
    for path, expected in (
            (PACKAGE / "guard-sources" / GUARD.name, manifest["guard_sha256"]),
            (PACKAGE / "guard-sources" / PROBE.name, manifest["guard_probe_sha256"])):
        if not path.is_file() or path.is_symlink() or sha_file(path) != expected:
            raise ValueError("reviewed guard source package changed")


def preflight(manifest: dict) -> dict:
    check_guard_sources(manifest)
    package_payload(manifest)
    if manifest["clone_image"] != CLONE_IMAGE:
        raise ValueError("isolated PostgreSQL image changed from reviewed digest")
    if docker_inspect(PG)["Image"] != manifest["clone_image"]:
        raise ValueError("running PostgreSQL image differs from reviewed clone image")
    schema = database_value("select version_num from alembic_version")
    if schema != BASE_SCHEMA:
        raise ValueError("schema head drift")
    assert_production_0092(production_schema_shape())
    selected = {}
    configs = {}
    for role, record in manifest["roles"].items():
        container = docker_inspect(ROLE_CONTAINER[role])
        if container["Image"] != record["base_image"] or container["State"].get("Health", {}).get("Status") != "healthy":
            raise ValueError(f"{role} image/health drift")
        original_path, rendered = compose_input(container, role, record["compose_sha256"])
        configs[role] = {"original_path": str(original_path), "rendered": rendered}
        for item in record["files"]:
            if live_hash(ROLE_CONTAINER[role], item["dest"]) != item["before_sha256"]:
                raise ValueError(f"{role} live file SHA drift: {item['dest']}")
        if container_inventory(ROLE_CONTAINER[role], role) != image_inventory(record["base_image"], role):
            raise ValueError(f"{role} running Python inventory differs from immutable base")
        selected[role] = container
    assert_single_api_ingress()
    env = dict(part.split("=", 1) for part in selected["api"]["Config"]["Env"] if "=" in part)
    if env.get("BUSINESS_WALLET_ACCESS_GRANT_ENABLED", "").lower() != "true":
        raise ValueError("wallet access grant feature flag is not true")
    for item in manifest["static"]:
        target = FRONTEND / item["dest"]
        if target.is_symlink():
            raise ValueError("static target symlink")
        actual = sha_file(target) if target.exists() else None
        if actual != item["before_sha256"]:
            raise ValueError(f"static SHA drift: {item['dest']}")
    merged_config = render_merged_baseline(manifest, configs)
    return {"schema": schema, "selected": selected, "configs": configs,
            "merged_config": merged_config,
            "containers": running_containers()}


def _check_rollback_archive(saved: dict) -> None:
    expected = saved.get("rollback_archive_sha256")
    archive = PRIVATE / "rollback-images.tar"
    if (not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected) or
            archive.is_symlink() or not archive.is_file() or sha_file(archive) != expected):
        raise ValueError("private rollback image archive missing or SHA changed")


def check_prepared(manifest: dict, *, expected_schema: str = BASE_SCHEMA,
                   isolated_clone: dict | None = None) -> dict:
    check_guard_sources(manifest)
    saved = read_private("baseline.json")
    if saved["manifest_sha256"] != sha_file(MANIFEST):
        raise ValueError("manifest changed since preparation")
    if sha_file(PRIVATE / "business.dump") != saved["backup_sha256"]:
        raise ValueError("private PostgreSQL backup changed")
    _check_rollback_archive(saved)
    if database_value("select version_num from alembic_version") != expected_schema:
        raise ValueError("schema changed since preparation")
    now = running_containers()
    for name, before in saved["containers"].items():
        if name in {"/" + value for value in ROLE_CONTAINER.values()}:
            if now.get(name) != before:
                raise ValueError(f"selected container changed since preparation: {name}")
        elif now.get(name) != before:
            raise ValueError(f"other container changed since preparation: {name}")
    expected_containers = set(saved["containers"])
    if isolated_clone is not None:
        clone_name = _clone_name(isolated_clone["clone"])
        clone_key = "/" + clone_name
        if clone_key in expected_containers:
            raise ValueError("isolated clone was already in baseline")
        expected_containers.add(clone_key)
    if set(now) != expected_containers:
        raise ValueError("running container set changed since preparation")
    if isolated_clone is not None:
        inspected = docker_inspect(clone_name)
        if (now[clone_key]["id"] != isolated_clone["clone_id"] or
                now[clone_key]["image"] != CLONE_IMAGE or
                inspected["Id"] != isolated_clone["clone_id"] or
                inspected["Image"] != CLONE_IMAGE or
                inspected["HostConfig"]["NetworkMode"] != "none" or
                inspected["State"]["Running"] is not True):
            raise ValueError("recorded isolated clone identity/network changed")
    configs = {}
    for role, record in manifest["roles"].items():
        container = docker_inspect(ROLE_CONTAINER[role])
        original_path, rendered = compose_input(container, role, record["compose_sha256"])
        configs[role] = {"original_path": str(original_path), "rendered": rendered}
        if container_inventory(ROLE_CONTAINER[role], role) != image_inventory(record["base_image"], role):
            raise ValueError(f"{role} running Python inventory changed")
        for item in record["files"]:
            if live_hash(ROLE_CONTAINER[role], item["dest"]) != item["before_sha256"]:
                raise ValueError(f"selected image target changed: {item['dest']}")
    if render_merged_baseline(manifest, configs) != read_private("merged-baseline-compose.json"):
        raise ValueError("merged baseline Compose changed since preparation")
    for item in manifest["static"]:
        target = FRONTEND / item["dest"]
        current = sha_file(target) if target.exists() else None
        if current != item["before_sha256"]:
            raise ValueError(f"static target changed: {item['dest']}")
    return saved


def prepare(manifest: dict) -> dict:
    if PRIVATE.exists():
        raise ValueError("private release already exists; review it before retry")
    snapshot = preflight(manifest)
    free = shutil.disk_usage(RELEASE_ROOT).free
    if free < 4_000_000_000:
        raise ValueError("less than 4 GB free; do not prepare snapshots")
    PRIVATE.mkdir(mode=0o700)
    os.chmod(PRIVATE, 0o700)
    for role, container in snapshot["selected"].items():
        write_private(f"{role}-container-inspect.json", container)
        original = Path(snapshot["configs"][role]["original_path"])
        target = PRIVATE / f"{role}-original-compose.json"
        shutil.copyfile(original, target)
        os.chmod(target, 0o600)
        if sha_file(target) != manifest["roles"][role]["compose_sha256"]:
            raise ValueError(f"{role} Compose changed during private snapshot")
        write_private(f"{role}-rendered-compose.json", snapshot["configs"][role]["rendered"])
    write_private("merged-baseline-compose.json", snapshot["merged_config"])
    for item in manifest["static"]:
        if item["before_sha256"] is None:
            continue
        source = FRONTEND / item["dest"]
        backup = PRIVATE / "static-before" / item["dest"]
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, backup)
        os.chmod(backup, 0o600)
        if sha_file(backup) != item["before_sha256"]:
            raise ValueError("static backup verification failed")
    backup = PRIVATE / "business.dump"
    run("docker", "exec", PG, "sh", "-c",
        'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc', output_file=backup)
    os.chmod(backup, 0o600)
    run("docker", "save", manifest["roles"]["api"]["base_image"],
        manifest["roles"]["worker"]["base_image"], output_file=PRIVATE / "rollback-images.tar")
    saved = {
        "prepared_utc": utc(), "schema": snapshot["schema"],
        "manifest_sha256": sha_file(MANIFEST), "backup_sha256": sha_file(backup),
        "rollback_archive_sha256": sha_file(PRIVATE / "rollback-images.tar"),
        "db_structure": database_value(STRUCTURE_SQL),
        "containers": snapshot["containers"],
    }
    write_private("baseline.json", saved)
    return {"prepared": True, "schema": BASE_SCHEMA,
            "target_containers": 2, "other_containers": len(saved["containers"]) - 2,
            "backup_sha256": saved["backup_sha256"]}


def _compose_files(version: str) -> list[str]:
    return [str(PRIVATE / f"{role}-{version}.json") for role in ("api", "worker")]


def _guard(operation: str, images: dict[str, list[str]] | None = None, services: list[str] | None = None,
           version: str | None = None) -> dict:
    command = ["python3", str(GUARD), operation]
    if operation == "check":
        if not isinstance(images, dict) or set(images) != {"api", "worker"} or any(
                not isinstance(images[role], list) or not images[role] for role in ("api", "worker")):
            raise ValueError("both image roles required by release protocol gate")
        for role in ("api", "worker"):
            for image in images[role]:
                command += ["--" + role + "-image", image]
    elif images is not None:
        raise ValueError("image list only applies to check")
    for path in _compose_files(version) if version else []:
        command += ["--compose", path]
    for service in services or []:
        command += ["--service", service]
    proof = json.loads(run(*command, timeout=360))
    if operation == "check":
        expected = {(role, image) for role in ("api", "worker") for image in images[role]}
        if (not isinstance(proof, list) or
                {(item.get("role"), item.get("image")) for item in proof
                 if isinstance(item, dict) and item.get("passed") is True} != expected or
                len(proof) != len(expected)):
            raise ValueError("incomplete role-qualified image protocol proof")
    return proof


def protocol_images(candidate: dict[str, str],
                    rollback_images: dict[str, str]) -> dict[str, list[str]]:
    if set(candidate) != {"api", "worker"} or set(rollback_images) != {"api", "worker"}:
        raise ValueError("candidate and rollback image roles incomplete")
    return {role: [candidate[role], rollback_images[role]] for role in ("api", "worker")}


def _check_frozen_compose(version: str, images: dict[str, str]) -> None:
    if version not in {"candidate", "rollback"} or set(images) != {"api", "worker"}:
        raise ValueError("both roles and a frozen Compose version are required")
    for role in ("api", "worker"):
        path = PRIVATE / f"{role}-{version}.json"
        rendered = json.loads(run("docker", "compose", "-p", "starchat", "-f", str(path),
                                  "config", "--format", "json"))
        original = read_private(f"{role}-rendered-compose.json")
        expected = dict(original)
        expected["services"] = dict(original["services"])
        expected["services"][ROLE_SERVICE[role]] = dict(original["services"][ROLE_SERVICE[role]])
        expected["services"][ROLE_SERVICE[role]]["image"] = images[role]
        if rendered != expected:
            raise ValueError(f"{role} {version} Compose changed")


def check_merged_compose(version: str, images: dict[str, str]) -> None:
    if version not in {"candidate", "rollback"} or set(images) != {"api", "worker"}:
        raise ValueError("both roles and a frozen Compose version are required")
    baseline = read_private("merged-baseline-compose.json")
    if set(baseline.get("services", {})) != set(ROLE_SERVICE.values()):
        raise ValueError("frozen merged baseline Compose roles changed")
    expected = copy.deepcopy(baseline)
    for role, service in ROLE_SERVICE.items():
        _image(images[role])
        expected["services"][service]["image"] = images[role]
    command = ["docker", "compose", "-p", "starchat"]
    for path in _compose_files(version):
        command += ["-f", path]
    rendered = json.loads(run(*command, "config", "--format", "json"))
    if rendered != expected:
        raise ValueError(f"merged {version} Compose changed")


def check_rollback_compose(manifest: dict, rollback_images: dict[str, str]) -> None:
    _check_frozen_compose("rollback", rollback_images)


def check_candidate_compose(manifest: dict, images: dict[str, str]) -> None:
    _check_frozen_compose("candidate", images)


def _render_compose(role: str, name: str, config: dict, expected_image: str) -> None:
    path = write_private(f"{role}-{name}.json", config)
    rendered = json.loads(run("docker", "compose", "-p", "starchat", "-f", str(path),
                              "config", "--format", "json"))
    original = read_private(f"{role}-rendered-compose.json")
    original["services"][ROLE_SERVICE[role]]["image"] = expected_image
    if rendered != original:
        raise ValueError("Compose roundtrip changed configuration beyond image")


def _build_overlay_image(role: str, base: str, base_inventory: dict[str, str],
                         files: list[dict], label: str) -> str:
    for item in files:
        if base_inventory.get(item["dest"]) != item["before_sha256"]:
            raise ValueError("immutable base image differs from live target SHA")
    context = PRIVATE / "build" / label
    context.mkdir(parents=True)
    base_tag = f"starchat-{RELEASE_ID}-{role}-base"
    candidate_tag = f"starchat-{RELEASE_ID}-{label}-candidate"
    if label == "rollback-api":
        candidate_tag = f"starchat-{RELEASE_ID}-rollback-compatible"
    run("docker", "tag", base, base_tag)
    if docker_inspect(base_tag)["Id"] != base:
        raise ValueError("base tag mismatch")
    lines = ["FROM " + base_tag]
    for index, item in enumerate(files):
        payload = PACKAGE / "payload" / item["source"]
        copy_name = f"file-{index:03}.py"
        shutil.copyfile(payload, context / copy_name)
        lines.append("COPY " + json.dumps([copy_name, item["dest"]]))
    (context / "Dockerfile").write_text("\n".join(lines) + "\n", encoding="utf-8")
    run("docker", "build", "--network", "none", "--pull=false", "--no-cache",
        "-t", candidate_tag, str(context),
        output_file=PRIVATE / f"build-{label}.private.log", timeout=900)
    image = docker_inspect(candidate_tag)["Id"]
    assert_exact_inventory_delta(
        base_inventory, image_inventory(image, role),
        {item["dest"]: item["after_sha256"] for item in files},
    )
    return image


def build(manifest: dict) -> dict:
    check_prepared(manifest)
    if (PRIVATE / "images.json").exists() or (PRIVATE / "rollback-images.json").exists():
        raise ValueError("candidate or rollback images already built")
    images = {}
    rollback_images = {}
    for role, record in manifest["roles"].items():
        base = record["base_image"]
        base_inventory = image_inventory(base, role)
        rollback_images[role] = base
        images[role] = (
            _build_overlay_image(role, base, base_inventory, record["files"], role)
            if record["files"] else base
        )
        original = read_private(f"{role}-rendered-compose.json")
        _render_compose(
            role, "candidate",
            compose_with_image(original, ROLE_SERVICE[role], images[role]), images[role],
        )
        _render_compose(
            role, "rollback",
            compose_with_image(original, ROLE_SERVICE[role], rollback_images[role]),
            rollback_images[role],
        )
    check_merged_compose("candidate", images)
    check_merged_compose("rollback", rollback_images)
    protocol_proofs = _guard("check", protocol_images(images, rollback_images))
    write_private("build-protocol-proofs.json", protocol_proofs)
    write_private("rollback-images.json", rollback_images)
    write_private("images.json", images)
    return {"built": True, "candidate_images": images, "rollback_images": rollback_images,
            "protocol_checked": ["candidate-api", "candidate-worker", "rollback-api", "rollback-worker"]}


def restore(manifest: dict) -> dict:
    check_prepared(manifest)
    if not (PRIVATE / "images.json").exists() or not (PRIVATE / "rollback-images.json").exists():
        raise ValueError("candidate and rollback image guards required first")
    if (PRIVATE / "restore-running.json").exists() or (PRIVATE / "restore.json").exists():
        raise ValueError("isolated restore already started")
    clone = "admin-entry-restore-" + uuid4().hex[:12]
    run("docker", "image", "inspect", CLONE_IMAGE)
    run("docker", "run", "-d", "--pull", "never", "--name", clone, "--network", "none",
        "-e", "POSTGRES_HOST_AUTH_METHOD=trust", "-e", "POSTGRES_DB=clone", CLONE_IMAGE)
    try:
        wait_clone_database(clone)
        run("docker", "exec", "-i", clone, "pg_restore", "-h", "127.0.0.1",
            "-U", "postgres", "-d", "clone",
            "--no-owner", "--no-privileges", "--exit-on-error",
            input_file=PRIVATE / "business.dump", output_file=PRIVATE / "restore.private.log", timeout=900)
        before = clone_snapshot(clone, after=True)
        structure = f"{before['tables']}:{before['constraints']}"
        if before["schema"] != BASE_SCHEMA or structure != read_private("baseline.json")["db_structure"]:
            raise ValueError("isolated restore schema/structure mismatch")
        assert_production_0092(before)
        inspected = docker_inspect(clone)
        if inspected["HostConfig"]["NetworkMode"] != "none" or inspected["State"]["Running"] is not True:
            raise ValueError("isolated clone lost network isolation")
        proof = {"restored_utc": utc(), "clone": clone, "clone_id": inspected["Id"],
                 "clone_network": "none", "schema": before["schema"], "db_structure": structure,
                 "before": before,
                 "backup_sha256": sha_file(PRIVATE / "business.dump"),
                 "candidate_images": read_private("images.json"),
                 "rollback_images": read_private("rollback-images.json")}
        write_private("restore-running.json", proof)
        return {"restored": True, "schema": before["schema"], "clone": clone,
                "network": "none", "container_only_dsn":
                "postgresql+psycopg://postgres@127.0.0.1:5432/clone"}
    except Exception:
        _remove_clone_with_volumes(clone)
        raise


def run_pg_probe(manifest: dict) -> dict:
    restored = read_private("restore-running.json")
    compatible = clone_compatibility_proof()
    if compatible["clone_id"] != restored["clone_id"]:
        raise ValueError("0092 clone compatibility proof identity mismatch")
    clone = restored["clone"]
    inspected = docker_inspect(clone)
    if inspected["Id"] != restored["clone_id"] or inspected["HostConfig"]["NetworkMode"] != "none":
        raise ValueError("isolated clone identity/network changed")
    if inspected["State"]["Running"] is not True:
        raise ValueError("isolated clone is not running")
    probe = PACKAGE / "pg-wallet-checks.py"
    if not probe.is_file() or sha_file(probe) != manifest["wallet_probe_sha256"]:
        raise ValueError("reviewed wallet PG probe SHA mismatch")
    images = read_private("images.json")
    if images != restored["candidate_images"]:
        raise ValueError("candidate image identity changed")
    runner = "wallet-workspace-pg-probe-" + uuid4().hex[:12]
    try:
        run("docker", "run", "--rm", "--pull", "never", "--name", runner,
            "--network", "container:" + clone,
            "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--memory", "1g", "--cpus", "2", "--pids-limit", "256",
            "--tmpfs", "/tmp:rw,nosuid,size=128m", "--workdir", "/tmp",
            "-e", "PYTHONDONTWRITEBYTECODE=1",
            "-e", "PYTHONPATH=/opt/business-api",
            "-e", "BUSINESS_ENVIRONMENT=test",
            "-e", "BUSINESS_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:5432/clone",
            "-v", str(probe) + ":/pg-wallet-checks.py:ro", "--entrypoint", "python",
            images["api"], "/pg-wallet-checks.py",
            output_file=PRIVATE / "pg-wallet.private.log", timeout=900)
    finally:
        subprocess.run(["docker", "rm", "-f", runner], capture_output=True, timeout=30)
    lines = (PRIVATE / "pg-wallet.private.log").read_text(encoding="utf-8").splitlines()
    result_line = json.loads(lines[-1]) if lines else None
    if (not isinstance(result_line, dict) or result_line.get("passed") is not True or
            result_line.get("database") != "isolated-clone" or
            {item.get("case") for item in result_line.get("cases", [])} != WALLET_PROBE_CASES or
            len(result_line["cases"]) != len(WALLET_PROBE_CASES) or
            any(item.get("passed") is not True for item in result_line["cases"])):
        raise ValueError("isolated wallet PG probe output incomplete")
    result = {"passed_utc": utc(), "probe_sha256": manifest["wallet_probe_sha256"],
              "candidate_api_image": images["api"], "clone_id": restored["clone_id"],
              "dsn_scope": "container-loopback-only", "exit": 0,
              "cases": result_line["cases"]}
    write_private("pg-wallet-result.json", result)
    return {"isolated_wallet_pg_passed": True, "candidate_api_image": images["api"], "exit": 0}


def restore_finalize(manifest: dict) -> dict:
    restored = read_private("restore-running.json")
    compatible = clone_compatibility_proof()
    if compatible["clone_id"] != restored["clone_id"]:
        raise ValueError("0092 clone compatibility proof identity mismatch")
    wallet = read_private("pg-wallet-result.json")
    if (wallet["probe_sha256"] != manifest["wallet_probe_sha256"] or wallet["exit"] != 0
            or wallet["clone_id"] != restored["clone_id"] or
            wallet["candidate_api_image"] != read_private("images.json")["api"]):
        raise ValueError("isolated wallet PG evidence mismatch")
    inspected = docker_inspect(restored["clone"])
    if inspected["Id"] != restored["clone_id"] or inspected["HostConfig"]["NetworkMode"] != "none":
        raise ValueError("isolated clone changed before cleanup")
    if clone_snapshot(restored["clone"], after=True) != compatible["after"]:
        raise ValueError("isolated 0092 clone changed during wallet probe")
    cleanup = _remove_clone_with_volumes(restored["clone"], inspected)
    if cleanup.get("clone_removed") is not True or cleanup.get("clone_volume_removed") is not True:
        raise ValueError("isolated clone cleanup proof incomplete")
    check_prepared(manifest)
    proof = {"finalized_utc": utc(), "before_schema": BASE_SCHEMA, "after_schema": TARGET_SCHEMA,
             "clone_before": restored["before"], "clone_after": compatible["after"],
             "backup_sha256": restored["backup_sha256"],
             "candidate_images": restored["candidate_images"],
             "rollback_images": restored["rollback_images"],
             "candidate_and_rollback_started": True,
             "wallet_probe_sha256": wallet["probe_sha256"],
             "wallet_cases_exit": wallet["exit"],
             "clone_removed": cleanup["clone_removed"],
             "clone_volume_removed": cleanup["clone_volume_removed"],
             "clone_volume_names": cleanup["clone_volume_names"]}
    write_private("restore.json", proof)
    return {"isolated_restore_and_wallet_pg_cases": True, "clone_removed": True,
            "clone_volume_removed": True,
            "schema": TARGET_SCHEMA}


def _selected_health(images: dict[str, str], *, wait: bool, frozen=None, replaced_roles=()) -> dict:
    if frozen is None:
        frozen = {role: read_private(f"{role}-container-inspect.json") for role in ("api", "worker")}
    for attempt in range(40 if wait else 1):
        status = {role: docker_inspect(ROLE_CONTAINER[role]) for role in ("api", "worker")}
        for role, current in status.items():
            original = frozen[role]
            if role not in replaced_roles and current.get("Id") != original.get("Id"):
                raise ValueError(f"{role} container identity drift outside guarded replacement")
            expected_restarts = (original.get("RestartCount")
                                 if current.get("Id") == original.get("Id") else 0)
            if (not isinstance(expected_restarts, int) or expected_restarts < 0 or
                    current.get("RestartCount") != expected_restarts):
                raise ValueError(f"{role} restart count differs from frozen baseline")
        if all(status[role]["Image"] == images[role] and
               status[role]["State"].get("Health", {}).get("Status") == "healthy"
               for role in status):
            return status
        if not wait:
            break
        if any(status[role]["State"]["Status"] in {"exited", "dead"} for role in status):
            break
        time.sleep(2)
    raise ValueError("selected services did not reach expected healthy images")


def _restart_counts(status: dict) -> dict[str, int]:
    return {role: status[role]["RestartCount"] for role in ("api", "worker")}


def _other_containers_unchanged(baseline: dict, manifest: dict) -> None:
    now = running_containers()
    before = baseline["containers"]
    changed = {"/" + ROLE_CONTAINER[role] for role, item in manifest["roles"].items() if item["files"]}
    other = set(before) - changed
    if set(now) - changed != other:
        raise ValueError("other running container set changed")
    if any(now[name] != before[name] for name in other):
        raise ValueError("other running container changed")


def _publish_static(manifest: dict) -> None:
    ordered = sorted(manifest["static"], key=lambda item: (item["dest"] == "admin.html",
                                                       item["dest"] == "src/admin-home.js", item["dest"]))
    for item in ordered:
        target = FRONTEND / item["dest"]
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
            raise ValueError(f"static target symlink: {item['dest']}")
        before = sha_file(target) if target.exists() else None
        if before != item["before_sha256"]:
            raise ValueError(f"static drift during publish: {item['dest']}")
        payload = PACKAGE / "payload" / item["source"]
        if payload.is_symlink() or not payload.is_file() or sha_file(payload) != item["after_sha256"]:
            raise ValueError(f"static payload drift during publish: {item['dest']}")
    for item in ordered:
        target = FRONTEND / item["dest"]
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
            raise ValueError(f"static target symlink during publish: {item['dest']}")
        current = sha_file(target) if target.exists() else None
        if current != item["before_sha256"]:
            raise ValueError(f"static drift during publish: {item['dest']}")
        _atomic_replace(target, PACKAGE / "payload" / item["source"])
        if sha_file(target) != item["after_sha256"]:
            raise ValueError("static write verification failed")


def _same_runtime_configuration(role: str) -> None:
    before = read_private(f"{role}-container-inspect.json")
    now = docker_inspect(ROLE_CONTAINER[role])
    def env_entries(inspected: dict) -> list[str]:
        entries = inspected["Config"].get("Env")
        if not isinstance(entries, list):
            raise ValueError(f"{role} runtime environment is malformed")
        keys = set()
        for entry in entries:
            if not isinstance(entry, str):
                raise ValueError(f"{role} runtime environment is malformed")
            key = entry.partition("=")[0]
            if not key or key in keys:
                raise ValueError(f"{role} runtime environment has duplicate or empty keys")
            keys.add(key)
        return sorted(entries)
    if env_entries(now) != env_entries(before):
        raise ValueError(f"{role} runtime environment changed")
    for field in ("Cmd", "Entrypoint", "WorkingDir", "User"):
        if now["Config"].get(field) != before["Config"].get(field):
            raise ValueError(f"{role} runtime configuration changed")
    for field in ("Binds", "Mounts", "NetworkMode", "RestartPolicy", "LogConfig"):
        if now["HostConfig"].get(field) != before["HostConfig"].get(field):
            raise ValueError(f"{role} runtime host configuration changed")


def _verify_post_switch_configuration(manifest: dict, images: dict[str, str],
                                      deployed: dict) -> dict:
    if deployed.get("images") != images:
        raise ValueError("deployed image proof changed")
    snapshot_name = deployed.get("guard_snapshot")
    expected_sha = deployed.get("guard_snapshot_sha256")
    if not isinstance(snapshot_name, str) or not Path(snapshot_name).is_absolute():
        raise ValueError("absolute guarded Compose snapshot is required")
    snapshot = Path(snapshot_name)
    if snapshot.is_symlink() or not snapshot.is_file() or sha_file(snapshot) != expected_sha:
        raise ValueError("guarded Compose snapshot changed")
    api = docker_inspect(ROLE_CONTAINER["api"])
    worker = docker_inspect(ROLE_CONTAINER["worker"])
    api_labels = api["Config"]["Labels"]
    if (api_labels.get("com.docker.compose.project") != "starchat" or
            api_labels.get("com.docker.compose.service") != ROLE_SERVICE["api"] or
            api_labels.get("com.docker.compose.project.config_files", "").split(",") != [snapshot_name]):
        raise ValueError("running API is not bound to guarded Compose snapshot")
    expected = copy.deepcopy(read_private("merged-baseline-compose.json"))
    for role, service in ROLE_SERVICE.items():
        expected["services"][service]["image"] = images[role]
    rendered = json.loads(run("docker", "compose", "-p", "starchat", "-f", snapshot_name,
                              "config", "--format", "json"))
    if rendered != expected:
        raise ValueError("guarded Compose rendering differs from frozen candidate")
    original_worker = read_private("worker-container-inspect.json")
    worker_labels = worker["Config"]["Labels"]
    original_labels = original_worker["Config"]["Labels"]
    worker_source = worker_labels.get("com.docker.compose.project.config_files")
    if (worker_labels.get("com.docker.compose.project") != "starchat" or
            worker_labels.get("com.docker.compose.service") != ROLE_SERVICE["worker"] or
            worker_source != original_labels.get("com.docker.compose.project.config_files") or
            not isinstance(worker_source, str) or "," in worker_source or
            sha_file(Path(worker_source)) != manifest["roles"]["worker"]["compose_sha256"]):
        raise ValueError("unchanged Worker Compose source changed")
    worker_rendered = json.loads(run("docker", "compose", "-p", "starchat", "-f", worker_source,
                                     "config", "--format", "json"))
    if worker_rendered != read_private("worker-rendered-compose.json"):
        raise ValueError("unchanged Worker Compose rendering changed")
    for role in ("api", "worker"):
        _same_runtime_configuration(role)
    return {"guard_snapshot_sha256": expected_sha,
            "worker_compose_sha256": manifest["roles"]["worker"]["compose_sha256"]}


def _post_switch_logs(since_utc: str) -> dict:
    if not isinstance(since_utc, str):
        raise ValueError("switch start timestamp missing")
    try:
        started = datetime.fromisoformat(since_utc)
    except ValueError as error:
        raise ValueError("switch start timestamp invalid") from error
    if started.tzinfo is None or started > datetime.now(timezone.utc):
        raise ValueError("switch start timestamp is not a past UTC instant")
    status = {}
    for role in ("api", "worker"):
        path = PRIVATE / f"post-switch-{role}-{uuid4().hex}.private.log"
        with path.open("xb") as output:
            os.chmod(path, 0o600)
            result = subprocess.run(
                ["docker", "logs", "--since", since_utc, "--tail",
                 str(POST_SWITCH_LOG_TAIL), ROLE_CONTAINER[role]],
                stdout=output, stderr=subprocess.STDOUT, timeout=60,
            )
        if result.returncode != 0:
            raise ValueError(f"{role} post-switch docker logs failed")
        size = path.stat().st_size
        if size > POST_SWITCH_LOG_MAX_BYTES:
            raise ValueError(f"{role} post-switch docker logs exceed private size limit")
        content = path.read_bytes().decode("utf-8", errors="replace")
        tracebacks = len(re.findall(r"(?m)^Traceback \(most recent call last\):", content))
        fatal = len(re.findall(r"(?im)\b(?:FATAL|CRITICAL|unhandled exception|"
                               r"exception in ASGI application)\b", content))
        exits = len(re.findall(r"(?im)\b(?:exited? with (?:code|status)|"
                               r"exited? unexpectedly|process (?:terminated|exited)|"
                               r"worker (?:died|exited))\b", content))
        if tracebacks or fatal or exits:
            raise ValueError(f"{role} post-switch logs contain a fatal event")
        status[role] = {"status": "clean", "lines": len(content.splitlines()),
                        "bytes": size, "tracebacks": tracebacks,
                        "fatal_exceptions": fatal, "exits": exits}
    return {"since_utc": since_utc, "tail": POST_SWITCH_LOG_TAIL, "roles": status}


def rollback(manifest: dict) -> dict:
    check_guard_sources(manifest)
    saved = read_private("baseline.json")
    if saved["manifest_sha256"] != sha_file(MANIFEST):
        raise ValueError("manifest drift blocks rollback")
    _check_rollback_archive(saved)
    if database_value("select version_num from alembic_version") != TARGET_SCHEMA:
        raise ValueError("0092 schema is required for same-schema rollback")
    images = read_private("images.json")
    rollback_images = read_private("rollback-images.json")
    if rollback_images["api"] == manifest["roles"]["api"]["base_image"] or rollback_images["worker"] != images["worker"]:
        raise ValueError("rollback must use the frozen current 0092 API and Worker images")
    package_payload(manifest)
    changed_services = ["business-api", "business-worker"]
    for role in ("api", "worker"):
        current = docker_inspect(ROLE_CONTAINER[role])["Image"]
        if current not in {images[role], manifest["roles"][role]["base_image"],
                           rollback_images[role]}:
            raise ValueError("later image release blocks rollback")
        _same_runtime_configuration(role)
    _other_containers_unchanged(saved, manifest)
    # Restore the old HTML first so new routes are not offered during rollback.
    ordered = sorted(manifest["static"], key=lambda item: (item["dest"] != "admin.html", item["dest"]))
    for item in ordered:
        target = FRONTEND / item["dest"]
        if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
            raise ValueError(f"static target symlink: {item['dest']}")
        current = sha_file(target) if target.exists() else None
        if current not in {item["before_sha256"], item["after_sha256"]}:
            raise ValueError(f"later static release blocks rollback: {item['dest']}")
        if item["before_sha256"] is not None:
            backup = PRIVATE / "static-before" / item["dest"]
            if not backup.is_file() or sha_file(backup) != item["before_sha256"]:
                raise ValueError(f"static backup mismatch: {item['dest']}")
    check_rollback_compose(manifest, rollback_images)
    check_merged_compose("candidate", images)
    check_merged_compose("rollback", rollback_images)
    assert_managed_api_ingress()
    check_guard_sources(manifest)
    protocol_proofs = _guard("check", protocol_images(images, rollback_images))
    existing = PRIVATE / "rollback-preswitch-protocol-proofs.json"
    if existing.exists():
        if json.loads(existing.read_text(encoding="utf-8")) != protocol_proofs:
            raise ValueError("rollback protocol evidence changed")
    else:
        write_private("rollback-preswitch-protocol-proofs.json", protocol_proofs)
    # This release changes no authentication protocol or schema. Keep admin
    # refresh families valid; the guarded API switch replaces only the image.
    for item in ordered:
        before_file = (PRIVATE / "static-before" / item["dest"]
                       if item["before_sha256"] is not None else None)
        before = before_file.read_bytes() if before_file else None
        candidate = (PACKAGE / "payload" / item["source"]).read_bytes()
        restore_static_file(FRONTEND / item["dest"], before_file, candidate, before)
    guard = _guard("rollback", services=changed_services, version="rollback")
    health = _selected_health(rollback_images, wait=True, replaced_roles=("api", "worker"))
    _other_containers_unchanged(saved, manifest)
    result = {"rolled_back_utc": utc(), "restored_services": changed_services,
              "static_files": len(ordered), "schema": database_value("select version_num from alembic_version"),
               "guard_snapshot": guard.get("snapshot") if guard else None,
               "data_downgrade": False, "management_sessions_preserved": True,
               "restart_counts": _restart_counts(health),
               "containers": health,
               "rollback_api_image": rollback_images["api"]}
    if not (PRIVATE / "rollback-result.json").exists():
        write_private("rollback-result.json", result)
    return result


def deploy(manifest: dict) -> dict:
    baseline = check_prepared(manifest, expected_schema=TARGET_SCHEMA)
    if not (PRIVATE / "restore.json").exists():
        raise ValueError("isolated PostgreSQL restore missing")
    images = read_private("images.json")
    rollback_images = read_private("rollback-images.json")
    proof = read_private("restore.json")
    if (proof["candidate_images"] != images or proof["rollback_images"] != rollback_images
            or proof["before_schema"] != BASE_SCHEMA
            or proof["after_schema"] != TARGET_SCHEMA
            or proof["candidate_and_rollback_started"] is not True
            or proof["backup_sha256"] != baseline["backup_sha256"]
            or proof["wallet_probe_sha256"] != manifest["wallet_probe_sha256"]
            or proof["wallet_cases_exit"] != 0 or proof["clone_removed"] is not True
            or proof.get("clone_volume_removed") is not True
            or proof.get("fence_passed") is not True):
        raise ValueError("restore evidence mismatch")
    assert_production_0092(production_schema_shape())
    check_candidate_compose(manifest, images)
    check_rollback_compose(manifest, rollback_images)
    check_merged_compose("candidate", images)
    check_merged_compose("rollback", rollback_images)
    if (PRIVATE / "switch-attempt.json").exists():
        raise ValueError("switch already attempted; inspect and use rollback")
    _other_containers_unchanged(baseline, manifest)
    check_guard_sources(manifest)
    protocol_proofs = _guard("check", protocol_images(images, rollback_images))
    write_private("preswitch-protocol-proofs.json", protocol_proofs)
    write_private("switch-attempt.json", {"started_utc": utc(), "images": images})
    try:
        result = _guard("deploy", services=services_to_switch(manifest), version="candidate")
        write_private("deploy-protocol-proofs.json", result["proofs"])
        guard_snapshot = Path(result["snapshot"])
        if not guard_snapshot.is_absolute() or guard_snapshot.is_symlink() or not guard_snapshot.is_file():
            raise ValueError("guarded Compose snapshot missing after switch")
        guard_snapshot_sha256 = sha_file(guard_snapshot)
        health = _selected_health(images, wait=True)
        _publish_static(manifest)
        _other_containers_unchanged(baseline, manifest)
        write_private("deployed.json", {"deployed_utc": utc(), "images": images,
                                        "restart_counts": _restart_counts(health),
                                        "guard_snapshot": result["snapshot"],
                                        "guard_snapshot_sha256": guard_snapshot_sha256})
        return {"deployed": True, "images": images, "static_files": len(manifest["static"]),
                "restart_counts": _restart_counts(health),
                "guard_snapshot": result["snapshot"],
                "guard_snapshot_sha256": guard_snapshot_sha256}
    except Exception:
        rollback(manifest)
        raise


def verify(manifest: dict) -> dict:
    if not (PRIVATE / "deployed.json").exists():
        raise ValueError("no successful deploy record")
    images = read_private("images.json")
    health = _selected_health(images, wait=False)
    if database_value("select version_num from alembic_version") != TARGET_SCHEMA:
        raise ValueError("schema changed after deploy")
    check_candidate_compose(manifest, images)
    check_merged_compose("candidate", images)
    post_switch = _verify_post_switch_configuration(manifest, images,
                                                     read_private("deployed.json"))
    _other_containers_unchanged(read_private("baseline.json"), manifest)
    for item in manifest["static"]:
        if sha_file(FRONTEND / item["dest"]) != item["after_sha256"]:
            raise ValueError(f"static candidate SHA changed: {item['dest']}")
    for role, record in manifest["roles"].items():
        for item in record["files"]:
            if live_hash(ROLE_CONTAINER[role], item["dest"]) != item["after_sha256"]:
                raise ValueError(f"running image target SHA changed: {item['dest']}")
    switch = read_private("switch-attempt.json")
    if switch.get("images") != images:
        raise ValueError("switch attempt image proof changed")
    post_switch_logs = _post_switch_logs(switch.get("started_utc"))
    result = {"verified_utc": utc(), "images": images, "schema": TARGET_SCHEMA,
              "restart_counts": _restart_counts(health),
              "guard_snapshot_sha256": post_switch["guard_snapshot_sha256"],
              "worker_compose_sha256": post_switch["worker_compose_sha256"],
              "post_switch_logs": post_switch_logs,
              "static_files": len(manifest["static"]), "other_containers_unchanged": True,
              "public_https": "separate server and workstation checks required"}
    write_private("verified.json", result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["preflight", "prepare", "build", "restore",
                                              "probe-clone", "run-pg-probe", "restore-finalize", "deploy",
                                              "verify", "rollback"])
    args = parser.parse_args()
    if PACKAGE != RELEASE_ROOT:
        raise SystemExit("server release script must run from its dedicated /opt/starchat release directory")
    manifest = validate_manifest(json.loads(MANIFEST.read_text(encoding="utf-8")))
    operations = {
        "preflight": lambda: {"preflight": True, "schema": preflight(manifest)["schema"]},
        "prepare": lambda: prepare(manifest), "build": lambda: build(manifest),
        "restore": lambda: restore(manifest),
        "probe-clone": lambda: probe_clone(manifest),
        "deploy": lambda: deploy(manifest),
        "run-pg-probe": lambda: run_pg_probe(manifest),
        "restore-finalize": lambda: restore_finalize(manifest),
        "verify": lambda: verify(manifest), "rollback": lambda: rollback(manifest),
    }
    print(json.dumps(operations[args.operation](), ensure_ascii=False), flush=True)


if __name__ == "__main__":
    raise SystemExit("Use reviewed server_release.py adapter; direct r3 execution is forbidden")
