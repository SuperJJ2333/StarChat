"""Freeze or verify all non-ignored mobile inputs for the Android 2216 build.

This deliberately supports the current uncommitted worktree. It records file
paths and SHA256 values only, never file contents or credentials. Run `create`
after `flutter pub get`, then pass its manifest SHA256 to the build driver.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path


VERSION = "0.4.47"
BUILD = 2216
GENERATED_INPUTS = (
    "apps/mobile_flutter/.dart_tool/package_config.json",
    "apps/mobile_flutter/.flutter-plugins-dependencies",
)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256")
    return digest.hexdigest()


def git_output(repo: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def source_files(repo: Path) -> list[dict[str, str]]:
    raw = git_output(
        repo,
        "-c",
        "core.quotepath=false",
        "ls-files",
        "-z",
        "--cached",
        "--others",
        "--exclude-standard",
        "--",
        "apps/mobile_flutter",
    )
    names = [part.decode("utf-8") for part in raw.split(b"\0") if part]
    if not names or len(names) != len(set(names)):
        raise ValueError("mobile input list is empty or contains duplicate paths")
    result: list[dict[str, str]] = []
    mobile_root = (repo / "apps/mobile_flutter").resolve(strict=True)
    for name in sorted(names):
        relative = Path(name)
        if (
            not name.startswith("apps/mobile_flutter/")
            or "\\" in name
            or relative.is_absolute()
            or any(part in (".", "..") for part in relative.parts)
        ):
            raise ValueError(f"invalid mobile input path: {name}")
        source = repo / relative
        resolved = source.resolve(strict=True)
        if not resolved.is_relative_to(mobile_root) or not source.is_file():
            raise ValueError(f"mobile input escapes its root or is not a file: {name}")
        result.append({"path": name, "sha256": sha256(source)})
    return result


def generated_inputs(repo: Path) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    mobile_root = (repo / "apps/mobile_flutter").resolve(strict=True)
    for name in GENERATED_INPUTS:
        path = repo / name
        if not path.is_file() or not path.resolve(strict=True).is_relative_to(mobile_root):
            raise ValueError(f"run flutter pub get before freezing: {name}")
        result.append({"path": name, "sha256": sha256(path)})
    return result


def snapshot(repo: Path) -> dict[str, object]:
    if git_output(repo, "ls-files", "-u", "--", "apps/mobile_flutter"):
        raise ValueError("unresolved mobile Git index entries")
    pubspec = (repo / "apps/mobile_flutter/pubspec.yaml").read_text(encoding="utf-8")
    config = (repo / "apps/mobile_flutter/lib/core/app_config.dart").read_text(encoding="utf-8")
    if not re.search(rf"(?m)^version:\s*{re.escape(VERSION)}\+{BUILD}\s*$", pubspec):
        raise ValueError("pubspec.yaml must be 0.4.47+2216 before freezing")
    if not re.search(rf"appVersionName\s*=\s*'{re.escape(VERSION)}'", config) or not re.search(
        r"compiledBuildNumber\s*=\s*2216\s*;", config
    ):
        raise ValueError("app_config.dart must be 0.4.47+2216 before freezing")
    head = git_output(repo, "rev-parse", "HEAD").decode("ascii").strip()
    if len(head) != 40:
        raise ValueError("invalid source commit")
    return {
        "schema": 1,
        "source_commit": head,
        "version": VERSION,
        "build": BUILD,
        "files": source_files(repo),
        "generated_inputs": generated_inputs(repo),
    }


def create(repo: Path, manifest: Path) -> dict[str, object]:
    data = snapshot(repo)
    data["created_at_utc"] = datetime.now(timezone.utc).isoformat()
    manifest.parent.mkdir(parents=True, exist_ok=True)
    with manifest.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(data, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write("\n")
    return {
        "manifest_sha256": sha256(manifest),
        "source_commit": data["source_commit"],
        "version": VERSION,
        "build": BUILD,
        "file_count": len(data["files"]),
    }


def verify(repo: Path, manifest: Path, expected_sha256: str) -> dict[str, object]:
    if len(expected_sha256) != 64 or any(c not in "0123456789abcdefABCDEF" for c in expected_sha256):
        raise ValueError("expected manifest SHA256 must be 64 hex characters")
    actual_sha256 = sha256(manifest)
    if actual_sha256 != expected_sha256.lower():
        raise ValueError("frozen manifest SHA256 differs")
    original = json.loads(manifest.read_text(encoding="utf-8"))
    if original.get("schema") != 1:
        raise ValueError("unsupported frozen manifest schema")
    current = snapshot(repo)
    for field in ("source_commit", "version", "build", "files", "generated_inputs"):
        if original.get(field) != current[field]:
            raise ValueError(f"frozen mobile input changed: {field}")
    return {
        "manifest_sha256": actual_sha256,
        "source_commit": current["source_commit"],
        "version": VERSION,
        "build": BUILD,
        "file_count": len(current["files"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("create", "verify"))
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    repo = args.repo.resolve(strict=True)
    manifest = args.manifest.resolve() if args.mode == "create" else args.manifest.resolve(strict=True)
    if args.mode == "create":
        report = create(repo, manifest)
    else:
        if args.expected_sha256 is None:
            parser.error("verify requires --expected-sha256")
        report = verify(repo, manifest, args.expected_sha256)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
