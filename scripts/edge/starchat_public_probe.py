"""Guarded, additive public-health Caddy pilot on the user-provided ECS.

Run on that Windows host with Python 3.11 over a trusted SSH stdin session.
Never prints the existing Caddyfile, its authentication hash, or request data.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request


BASE = Path(r"C:\ProgramData\Employ26\Config")
CONFIG = BASE / "Caddyfile"
CADDY = Path(r"C:\ProgramData\Employ26\Caddy\2.11.4\caddy.exe")
BACKUP_DIR = BASE / "backup-starchat-edge-probe-20260925"
STAGE_DIR = BASE / "stage-starchat-edge-probe-20260925"
ROLLBACK_DIR = BASE / "rollback-starchat-edge-probe-20260925"
BACKUP = BACKUP_DIR / "Caddyfile"
STAGED = STAGE_DIR / "Caddyfile"
ROLLBACK_STAGE = ROLLBACK_DIR / "Caddyfile"
EXPECTED_ORIGINAL = "e045e52f75f5436e53e793c15cee415eef89ef8a14cb6019168b1e01d6b52945"
EXPECTED_RUNTIME = "f989ae43dbba9afb60f361b30cb50ccce87d012b2876f990479e1de5fd4c0776"
MARKER = "# StarChat edge-cn-probe public-health pilot 2026-09-25"
BLOCK = f"""

{MARKER}
edge-cn-probe.liuhetong888.com {{
    @public_health {{
        method GET
        path /api/v1/health/ready /_matrix/client/versions
    }}
    handle @public_health {{
        reverse_proxy https://207.56.8.8 {{
            header_up Host liuhetong888.com
            header_up -Authorization
            header_up -Cookie
            lb_retries 0
            transport http {{
                tls_server_name liuhetong888.com
            }}
        }}
    }}
    handle {{
        respond 404
    }}
}}
""".encode("utf-8")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_digest(value: object) -> str:
    return digest(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def check_paths() -> None:
    base = BASE.resolve(strict=True)
    for path in (CONFIG, CADDY):
        if not path.is_file():
            raise RuntimeError("required-file-missing")
    for directory in (BACKUP_DIR, STAGE_DIR, ROLLBACK_DIR):
        if directory.resolve(strict=False).parent != base:
            raise RuntimeError("staging-path-outside-config")
    if CONFIG.resolve(strict=True).parent != base:
        raise RuntimeError("config-path-unexpected")


def run(args: list[str], *, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError("native-command-failed")
    return result


def robocopy(source: Path, target_dir: Path) -> Path:
    target_dir.mkdir(exist_ok=True)
    result = subprocess.run(
        ["robocopy", str(source.parent), str(target_dir), source.name,
         "/COPYALL", "/DCOPY:DAT", "/IS", "/SECFIX", "/R:0", "/W:0"],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode > 7:
        raise RuntimeError("acl-preserving-copy-failed")
    target = target_dir / source.name
    if digest(target.read_bytes()) != digest(source.read_bytes()):
        raise RuntimeError("copy-hash-mismatch")
    return target


def adapted(path: Path) -> object:
    response = run([str(CADDY), "adapt", "--config", str(path), "--adapter", "caddyfile"])
    return json.loads(response.stdout)


def live_config() -> object:
    # The admin JSON includes Employ26 authentication config. Never inherit a
    # machine proxy for this loopback-only read.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:2019/config/", timeout=10) as response:
        return json.load(response)


def validate(path: Path) -> None:
    run([str(CADDY), "validate", "--config", str(path), "--adapter", "caddyfile"])


def reload() -> None:
    run([str(CADDY), "reload", "--config", str(CONFIG), "--adapter", "caddyfile",
         "--address", "127.0.0.1:2019"], timeout=40)


def require_original_runtime(*, reload_if_stale: bool) -> None:
    if json_digest(live_config()) == EXPECTED_RUNTIME:
        return
    if reload_if_stale:
        reload()
        if json_digest(live_config()) == EXPECTED_RUNTIME:
            return
    raise RuntimeError("rollback-runtime-mismatch")


def restore_backup() -> None:
    if digest(BACKUP.read_bytes()) != EXPECTED_ORIGINAL:
        raise RuntimeError("rollback-backup-drift")
    rollback_copy = robocopy(BACKUP, ROLLBACK_DIR)
    os.replace(rollback_copy, CONFIG)
    validate(CONFIG)
    reload()
    if digest(CONFIG.read_bytes()) != EXPECTED_ORIGINAL:
        raise RuntimeError("rollback-content-mismatch")
    require_original_runtime(reload_if_stale=False)


def prepare() -> None:
    original = CONFIG.read_bytes()
    if digest(original) != EXPECTED_ORIGINAL or MARKER.encode() in original:
        raise RuntimeError("unexpected-original-config")
    if json_digest(adapted(CONFIG)) != EXPECTED_RUNTIME:
        raise RuntimeError("original-file-drift")
    if json_digest(live_config()) != EXPECTED_RUNTIME:
        raise RuntimeError("runtime-file-drift")
    backup = robocopy(CONFIG, BACKUP_DIR)
    if digest(backup.read_bytes()) != EXPECTED_ORIGINAL:
        raise RuntimeError("backup-mismatch")
    if STAGED.exists():
        if STAGED.read_bytes() != original + BLOCK:
            raise RuntimeError("existing-stage-drift")
        validate(STAGED)
        print(json.dumps({"stage": "prepared", "passed": True,
                          "candidate_sha256": digest(STAGED.read_bytes()),
                          "already_prepared": True}, sort_keys=True))
        return
    candidate = robocopy(CONFIG, STAGE_DIR)
    with candidate.open("ab") as handle:
        handle.write(BLOCK)
        handle.flush()
        os.fsync(handle.fileno())
    if not candidate.read_bytes().startswith(original):
        raise RuntimeError("candidate-not-additive")
    validate(candidate)
    new_json = adapted(candidate)
    if json_digest(new_json) == EXPECTED_RUNTIME:
        raise RuntimeError("candidate-no-change")
    print(json.dumps({"stage": "prepared", "passed": True,
                      "original_sha256": EXPECTED_ORIGINAL,
                      "candidate_sha256": digest(candidate.read_bytes()),
                      "additive_bytes": len(BLOCK),
                      "runtime_equal_to_original_file": True,
                      "backup_robocopy_copyall_ok": True,
                      "candidate_validated": True}, sort_keys=True))


def activate() -> None:
    original = CONFIG.read_bytes()
    candidate = STAGED.read_bytes()
    if digest(original) != EXPECTED_ORIGINAL or not candidate.startswith(original):
        raise RuntimeError("activation-input-drift")
    if candidate[len(original):] != BLOCK:
        raise RuntimeError("candidate-content-drift")
    if digest(BACKUP.read_bytes()) != EXPECTED_ORIGINAL:
        raise RuntimeError("backup-unavailable")
    if json_digest(live_config()) != EXPECTED_RUNTIME:
        raise RuntimeError("runtime-drift")
    validate(STAGED)
    expected_new = json_digest(adapted(STAGED))
    os.replace(STAGED, CONFIG)
    try:
        reload()
        if json_digest(live_config()) != expected_new:
            raise RuntimeError("runtime-candidate-mismatch")
    except Exception as error:
        try:
            restore_backup()
        except Exception as rollback_error:
            raise RuntimeError("activation-and-rollback-failed") from rollback_error
        raise RuntimeError("activation-failed-original-restored") from error
    print(json.dumps({"stage": "active", "passed": True,
                      "candidate_sha256": digest(CONFIG.read_bytes()),
                      "runtime_matches_file": True,
                      "backup_sha256": digest(BACKUP.read_bytes())}, sort_keys=True))


def rollback() -> None:
    if digest(CONFIG.read_bytes()) == EXPECTED_ORIGINAL:
        require_original_runtime(reload_if_stale=True)
        print(json.dumps({"stage": "rolled_back", "passed": True,
                          "already_original": True}))
        return
    if CONFIG.read_bytes() != BACKUP.read_bytes() + BLOCK:
        raise RuntimeError("unexpected-running-config")
    restore_backup()
    print(json.dumps({"stage": "rolled_back", "passed": True,
                      "original_sha256": EXPECTED_ORIGINAL}, sort_keys=True))


def main() -> None:
    check_paths()
    if sys.argv[1:] == ["prepare"]:
        prepare()
    elif sys.argv[1:] == ["activate"]:
        activate()
    elif sys.argv[1:] == ["rollback"]:
        rollback()
    else:
        raise RuntimeError("invalid-operation")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # All branch errors above are fixed literals; do not print config data.
        print(json.dumps({"passed": False, "error": str(exc)}), file=sys.stderr)
        raise SystemExit(1)
