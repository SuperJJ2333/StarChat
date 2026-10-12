"""Bind the completed Flutter gates to a CI-metadata-only successor."""
from __future__ import annotations

import hashlib
import json
import re
import runpy
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
ORIGINAL = "ec9a38a882096d80ff4a6ed1e31078dae95ee641"
FINAL = "e432414276af7d6fe73afd9afc8b41d7bfd4b5b7"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(REPO), *args], text=True).strip()


def main() -> None:
    started = datetime.now(timezone.utc).isoformat()
    assert git("rev-parse", "HEAD") == FINAL
    assert git("status", "--porcelain", "--", "apps/mobile_flutter") == ""
    changes = git("diff", "--name-only", ORIGINAL, FINAL).splitlines()
    assert changes == [".github/workflows/ios-enterprise-package.yml"], changes
    helper = runpy.run_path(str(HERE / "freeze_mobile_input.py"))
    original = json.loads((HERE / "mobile-input-manifest.json").read_text("utf-8"))
    current = helper["snapshot"](REPO)
    assert original["source_commit"] == ORIGINAL
    assert current["source_commit"] == FINAL
    for field in ("schema", "version", "build", "files", "generated_inputs"):
        assert current[field] == original[field], f"Changed mobile closure: {field}"
    final_manifest = HERE / "final-mobile-input-manifest.json"
    created = helper["create"](REPO, final_manifest)
    flutter = json.loads((HERE / "flutter/receipt.json").read_text("utf-8"))
    analyze = json.loads((HERE / "analyze/receipt.json").read_text("utf-8"))
    gates = {}
    for name, receipt in (("flutter", flutter), ("analyze", analyze)):
        assert receipt["source_commit"] == ORIGINAL
        assert receipt["exit_code"] == 0 and receipt["failure"] is None
        assert receipt["manifest_sha256"] == digest(HERE / "mobile-input-manifest.json")
        before = json.loads((HERE / name / "input-before.json").read_text("utf-8-sig"))
        after = json.loads((HERE / name / "input-after.json").read_text("utf-8-sig"))
        assert before == after
        for path, expected in receipt["native_dll_sha256"].items():
            assert digest(Path(path)) == expected, f"Native runtime changed: {path}"
        gates[name] = {
            "reused_from_source_commit": ORIGINAL,
            "accepted_for_source_commit": FINAL,
            "receipt_sha256": digest(HERE / name / "receipt.json"),
            "log_sha256": digest(HERE / name / "gate.log"),
            "actual_exit_code": 0,
            "reason": "Complete mobile file list and all SHA256s, generated inputs, pinned lock, and native runtime unchanged; successor only changes CI version literals.",
        }
    log = (HERE / "flutter/gate.log").read_text("utf-8")
    result = re.search(r"\+(\d+)(?: ~(\d+))?: All tests passed!", log)
    assert result, "Missing complete Flutter result"
    gates["flutter"]["passed"] = int(result[1])
    gates["flutter"]["skipped"] = int(result[2] or 0)
    gates["flutter"]["failed"] = 0
    assert "No issues found!" in (HERE / "analyze/gate.log").read_text("utf-8")
    report = {
        "schema": 1,
        "started_utc": started,
        "ended_utc": datetime.now(timezone.utc).isoformat(),
        "original_source_commit": ORIGINAL,
        "final_source_commit": FINAL,
        "changed_paths": changes,
        "mobile_file_count": len(current["files"]),
        "mobile_file_list_and_sha256_equal": True,
        "generated_inputs_equal": True,
        "original_manifest_sha256": digest(HERE / "mobile-input-manifest.json"),
        "final_manifest": created,
        "gates": gates,
        "python_boundaries": "Successor changes workflow contract input; original failing suite is not reused as passing. A fresh whole Python/mobile suite is required and separately recorded.",
        "ios_workflow_execution": "not_triggered",
        "ios_publication": "not_executed",
    }
    with (HERE / "ci-mobile-gate-reuse.json").open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(report, stream, indent=2, ensure_ascii=False, sort_keys=True)
        stream.write("\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
