"""Frozen, exact-scope wallet workspace release package for the 0092 baseline.

This file is inert until a reviewed, frozen manifest.json and payload exist.
No command in this file is run by importing it. Run `python3 release.py --help`.
"""

from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
from uuid import uuid4


os.umask(0o077)
PACKAGE = Path(__file__).resolve().parent
MANIFEST = PACKAGE / "manifest.json"
FRONTEND = Path("/opt/starchat/frontend")
GUARD = Path("/opt/starchat/ops/refresh-guards/business_release_guard.py")
PROBE = GUARD.with_name("business_refresh_image_probe.py")
PG = "starchat-business-postgres-1"
ROLE_CONTAINER = {"api": "starchat-business-api-1", "worker": "starchat-business-worker-1"}
ROLE_SERVICE = {"api": "business-api", "worker": "business-worker"}
IMAGE_ROOTS = {
    "api": ["/opt/business-api/app", "/opt/business-api/migrations"],
    "worker": ["/opt/business-worker/app", "/usr/local/lib/python3.12/site-packages/app"],
}
HEX = re.compile(r"[0-9a-f]{64}\Z")
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}\Z")
RELEASE_ID = "wallet-workspace-20260929-v1"
BASE_SCHEMA = "0092_admin_session_entry_mode"
TARGET_SCHEMA = "0092_admin_session_entry_mode"
API_SOURCES = frozenset({
    "services/business-api/app/api/admin_wallet_owner_transfers.py",
    "services/business-api/app/modules/wallet/owner_transfers.py",
})
STATIC_SOURCES = frozenset({
    "frontend/admin.html",
    "frontend/src/admin-api.js",
    "frontend/src/admin-chain-panel.js",
    "frontend/src/admin-chain-view-state.js",
    "frontend/src/admin-dashboard.js",
    "frontend/src/admin-home.js",
    "frontend/src/admin-manual-wallet-panel.js",
    "frontend/src/admin-session.js",
    "frontend/src/admin-wallet-access.js",
    "frontend/src/styles/admin-wallet.css",
    "frontend/src/styles/tokens.css",
})
NEW_STATIC = "frontend/src/admin-chain-view-state.js"
GIT_COMMIT = re.compile(r"[0-9a-f]{40}\Z")


def utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha_bytes(data: bytes) -> str:
    return sha256(data).hexdigest()


def sha_file(path: Path) -> str:
    return sha_bytes(path.read_bytes())


def _relative(value: str, *, prefix: str, label: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (path.is_absolute() or not path.parts or path.parts[0] != prefix
            or ".." in path.parts or "." in path.parts or "\\" in value):
        raise ValueError(f"invalid {label} path: {value}")
    return path


def _static_dest(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts or "." in path.parts or "\\" in value:
        raise ValueError(f"invalid static path: {value}")
    if path.name == "download.html" or path.parts[0] in {"downloads", "assets"}:
        raise ValueError("download.html and iOS/download assets are outside this release")
    return path


def _sha(value: object, label: str, *, nullable: bool = False) -> None:
    if nullable and value is None:
        return
    if not isinstance(value, str) or not HEX.fullmatch(value):
        raise ValueError(f"invalid {label} SHA-256")


def _image(value: object) -> None:
    if not isinstance(value, str) or not IMAGE_ID.fullmatch(value):
        raise ValueError("immutable sha256 image ID required")


def validate_manifest(data: dict) -> dict:
    if not isinstance(data, dict) or data.get("frozen") is not True:
        raise ValueError("manifest must be frozen after final review")
    if (data.get("release_id") != RELEASE_ID or
            data.get("before_schema") != BASE_SCHEMA or
            data.get("after_schema") != TARGET_SCHEMA):
        raise ValueError("wrong release identity or schema transition")
    _sha(data.get("guard_sha256"), "guard")
    _sha(data.get("guard_probe_sha256"), "guard probe")
    if not isinstance(data.get("source_commit"), str) or not GIT_COMMIT.fullmatch(data["source_commit"]):
        raise ValueError("exact source commit required")
    _sha(data.get("wallet_probe_sha256"), "wallet PG probe")
    _image(data.get("clone_image"))
    roles = data.get("roles")
    if not isinstance(roles, dict) or set(roles) != {"api", "worker"}:
        raise ValueError("exactly api and worker roles required")
    for role, record in roles.items():
        _image(record.get("base_image"))
        _sha(record.get("compose_sha256"), role + " Compose")
        files = record.get("files")
        if not isinstance(files, list) or (role == "api" and len(files) != 2) or (role == "worker" and files):
            raise ValueError(f"{role} overlay list invalid")
        seen: set[str] = set()
        for item in files:
            source = _relative(item.get("source", ""), prefix="services", label="source")
            expected_prefix = PurePosixPath("services/business-" + role + "/app")
            if role == "api" and source.parts[:3] != expected_prefix.parts:
                raise ValueError("API source outside business-api/app")
            if role == "worker" and source.parts[:3] not in {
                    expected_prefix.parts, PurePosixPath("services/business-api/app").parts}:
                raise ValueError("Worker source outside approved app roots")
            dest = item.get("dest", "")
            if not isinstance(dest, str) or not any(
                    dest.startswith(root + "/") for root in IMAGE_ROOTS[role]):
                raise ValueError("image destination outside approved roots")
            if ".." in PurePosixPath(dest).parts or "\\" in dest or not dest.endswith(".py"):
                raise ValueError("invalid image destination")
            if dest in seen:
                raise ValueError("duplicate image destination")
            if role == "api" and (str(source) not in API_SOURCES or
                    dest != "/opt/business-api/" + str(source).removeprefix("services/business-api/")):
                raise ValueError("API overlay must use the two reviewed destinations")
            seen.add(dest)
            _sha(item.get("before_sha256"), "image before")
            _sha(item.get("after_sha256"), "image after")
        if role == "api" and {item["source"] for item in files} != API_SOURCES:
            raise ValueError("two exact API sources are required")
    static = data.get("static")
    if not isinstance(static, list) or len(static) != len(STATIC_SOURCES):
        raise ValueError("eleven exact static targets required")
    seen_static: set[str] = set()
    for item in static:
        source = _relative(item.get("source", ""), prefix="frontend", label="static source")
        dest = _static_dest(item.get("dest", ""))
        if source.parts[1:] != dest.parts:
            raise ValueError("static source/destination mismatch")
        if "staging_source" in item or str(source) not in STATIC_SOURCES:
            raise ValueError("static overlay outside reviewed source set")
        if str(dest) in seen_static:
            raise ValueError("duplicate static destination")
        seen_static.add(str(dest))
        _sha(item.get("before_sha256"), "static before", nullable=True)
        _sha(item.get("after_sha256"), "static after")
        if (item.get("before_sha256") is None) != (str(source) == NEW_STATIC):
            raise ValueError("only the new chain state module may be absent before release")
    if {item["source"] for item in static} != STATIC_SOURCES:
        raise ValueError("static source set differs from the eleven reviewed paths")
    return data


def compose_with_image(config: dict, service: str, image: str) -> dict:
    _image(image)
    services = set(config.get("services", {}))
    if (service not in {"business-api", "business-worker"} or
            service not in services or
            services not in ({service}, {"business-api", "business-worker"})):
        raise ValueError("Compose must contain only the selected business role(s)")
    new = copy.deepcopy(config)
    new["services"][service]["image"] = image

    def escape(value):
        if isinstance(value, str):
            return value.replace("$", "$$")
        if isinstance(value, list):
            return [escape(part) for part in value]
        if isinstance(value, dict):
            return {key: escape(part) for key, part in value.items()}
        return value

    return escape(new)


def assert_exact_inventory_delta(before: dict[str, str], after: dict[str, str], expected: dict[str, str]) -> None:
    changed = {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}
    if changed != set(expected):
        raise ValueError(f"unlisted image file changes: {sorted(changed ^ set(expected))}")
    if any(after.get(path) != digest for path, digest in expected.items()):
        raise ValueError("final image file SHA mismatch")


def services_to_switch(manifest: dict) -> list[str]:
    validate_manifest(manifest)
    return ["business-" + role for role in ("worker", "api") if manifest["roles"][role]["files"]]


def restore_static_file(target: Path, backup: Path | None, candidate: bytes, before: bytes | None) -> None:
    current = target.read_bytes() if target.exists() else None
    if current == before:
        return
    if current != candidate:
        raise ValueError(f"static drift blocks rollback: {target}")
    if before is None:
        target.unlink()
        return
    if backup is None or not backup.is_file() or backup.read_bytes() != before:
        raise ValueError(f"static backup mismatch: {target}")
    _atomic_replace(target, backup)


def stage_payload(manifest: dict, repo: Path, package: Path) -> int:
    validate_manifest(manifest)
    destination = package / "payload"
    if destination.exists():
        raise ValueError("payload already exists; use a new reviewed package")
    sources = {item["source"]: item["after_sha256"]
               for role in manifest["roles"].values() for item in role["files"]}
    staging_sources = {name: name for name in sources}
    for item in manifest["static"]:
        if item["source"] in sources and sources[item["source"]] != item["after_sha256"]:
            raise ValueError("one source has conflicting expected hashes")
        sources[item["source"]] = item["after_sha256"]
        staging_sources[item["source"]] = item.get("staging_source", item["source"])
    resolved_repo = repo.resolve(strict=True)
    for name, expected in sources.items():
        path = repo / staging_sources[name]
        if (not path.is_file() or path.is_symlink() or
                not path.resolve(strict=True).is_relative_to(resolved_repo) or
                sha_file(path) != expected):
            raise ValueError(f"source mismatch: {name}")
    for name in sources:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repo / staging_sources[name], target)
        if sha_file(target) != sources[name]:
            raise ValueError(f"staged payload mismatch: {name}")
    return len(sources)


def _atomic_replace(target: Path, source: Path) -> None:
    if target.is_symlink() or any(parent.is_symlink() for parent in target.parents if parent != Path("/")):
        raise ValueError("refuse symlinked static path")
    target.parent.mkdir(parents=True, exist_ok=True)
    template = target if target.exists() else target.parent
    metadata = template.stat()
    temporary = target.with_name(target.name + ".admin-entry-" + uuid4().hex)
    try:
        shutil.copyfile(source, temporary)
        os.chmod(temporary, stat.S_IMODE(metadata.st_mode) if target.exists() else 0o644)
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["validate", "stage"])
    parser.add_argument("--repo", type=Path)
    args = parser.parse_args()
    data = validate_manifest(json.loads(MANIFEST.read_text(encoding="utf-8")))
    if args.operation == "validate":
        print(json.dumps({"release_id": data["release_id"], "frozen": True,
                          "roles": {key: len(value["files"]) for key, value in data["roles"].items()},
                          "static_files": len(data["static"])}))
    elif args.operation == "stage":
        if args.repo is None:
            raise ValueError("--repo is required for staging")
        print(json.dumps({"staged_files": stage_payload(data, args.repo, PACKAGE)}))


if __name__ == "__main__":
    raise SystemExit("Use reviewed server_release.py adapter; direct r3 execution is forbidden")
