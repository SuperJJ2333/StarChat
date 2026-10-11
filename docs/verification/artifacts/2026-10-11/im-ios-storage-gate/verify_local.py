"""Local structural evidence only; this does not execute or compile Swift."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone

import yaml

ROOT = Path(__file__).resolve().parents[5]
OUT = Path(__file__).resolve().parent
BASE = "9dcd48441bff06d8c69e20255dd9189719bf50c2"
PRIVACY = "d17689f2c5010e9659846a503173ac7b0b4a08fb"
FILES = [
    "apps/mobile_flutter/ios/Runner/IOSMediaStoragePolicy.swift",
    "apps/mobile_flutter/ios/RunnerTests/IOSMediaStoragePolicyTests.swift",
    ".github/workflows/im-native-storage.yml",
]


def blob(ref, path):
    return subprocess.check_output(["git", "show", ref + ":" + path], cwd=ROOT)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


policy = (ROOT / FILES[0]).read_text(encoding="utf-8")
inverse = policy.replace(
    "  // Kept separate so entry safety is testable even on Simulator filesystems\n"
    "  // without Data Protection. Every production apply still validates first.\n"
    "  func validateEntry(_ url: URL, inside root: URL, directory: Bool = false) throws -> String {",
    "  private func apply(_ url: URL, inside root: URL, directory: Bool = false) throws {",
).replace(
    "    return path\n  }\n\n"
    "  private func apply(_ url: URL, inside root: URL, directory: Bool = false) throws {\n"
    "    let path = try validateEntry(url, inside: root, directory: directory)\n", ""
)
assert inverse == blob(BASE, FILES[0]).decode(), "Production delta exceeds the exact validator extraction"
assert "targetEnvironment" not in policy and "XCTSkip" not in policy

tests = (ROOT / FILES[1]).read_text(encoding="utf-8")
test_names = re.findall(r"  func (test\w+)\(\) throws", tests)
assert len(test_names) == 8
assert tests.count("    try requireDataProtection()") == 4
assert "#else\n      return false\n      #endif" in tests

workflow = yaml.safe_load((ROOT / FILES[2]).read_text(encoding="utf-8"))
scripts = []
for step in workflow["jobs"]["ios-storage"]["steps"]:
    scripts += re.findall(r"python3 <<'PY'\n(.*?)\nPY", step.get("run", ""), re.S)
assert len(scripts) == 3
for script in scripts:
    compile(script, FILES[2], "exec")

# Execute only the result formatter, using an explicitly synthetic summary.
# It must preserve supplied counts, not convert skipped tests into passed tests.
fixture = OUT / "synthetic-summary"
fixture.mkdir(exist_ok=True)
result = {"issues": {"testFailureSummaries": {"_values": []}}}
summary = {"totalTestCount": 8, "passedTests": 4, "skippedTests": 4, "failedTests": 0}
(fixture / "result.json").write_text(json.dumps(result), encoding="utf-8")
(fixture / "test-summary.json").write_text(json.dumps(summary), encoding="utf-8")
markdown = fixture / "step-summary.md"
markdown.write_text("", encoding="utf-8")
environment = dict(os.environ, STORAGE_EVIDENCE=str(fixture), GITHUB_STEP_SUMMARY=str(markdown))
formatter = subprocess.run(["python", "-c", scripts[-1]], env=environment, text=True, capture_output=True)
assert formatter.returncode == 0, formatter.stderr
rendered = markdown.read_text(encoding="utf-8")
assert "SKIP is not PASS" in rendered
assert json.loads(rendered.split("```json\n", 1)[1].split("\n```", 1)[0]) == summary

privacy_test = subprocess.run(
    ["python", "-m", "pytest", "tests/mobile/test_ios_storage_privacy.py", "-q"],
    cwd=ROOT, text=True, capture_output=True,
)
assert privacy_test.returncode == 0, privacy_test.stdout + privacy_test.stderr
(OUT / "privacy-test.txt").write_text(privacy_test.stdout + privacy_test.stderr, encoding="utf-8")
for path in ["apps/mobile_flutter/ios/Runner/PrivacyInfo.xcprivacy",
             "apps/mobile_flutter/ios/Runner.xcodeproj/project.pbxproj"]:
    assert blob(BASE, path) == blob(PRIVACY, path), "Privacy review input changed after frozen commit"

evidence = {
    "at_utc": datetime.now(timezone.utc).isoformat(),
    "base": BASE,
    "privacy_review_commit": PRIVACY,
    "checks": ["exact inverse extraction equals baseline Swift", "no production simulator bypass",
               "8 XCTest cases; 4 explicit capability-gated success cases", "YAML and 3 embedded Python blocks parse",
               "synthetic formatter preserves 4 PASS + 4 SKIP + 0 FAIL counts", "privacy plist/PBX pytest exit 0"],
    "swift_execution": "NOT RUN: Windows host lacks Xcode/Swift iOS SDK; macOS CI required",
    "verify_ps1": "NOT RUN: isolated checkout has no .env; native-only task defers full candidate gate to root",
    "inputs": {path: {"baseline_git_blob_sha256": sha(blob(BASE, path)),
                     "candidate_workspace_bytes_sha256": sha((ROOT / path).read_bytes())} for path in FILES},
    "synthetic_formatter_exit": formatter.returncode,
    "privacy_test_exit": privacy_test.returncode,
}
(OUT / "local-verification.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
print(json.dumps(evidence, indent=2))
