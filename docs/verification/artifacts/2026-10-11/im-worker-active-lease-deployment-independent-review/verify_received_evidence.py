"""Read exact final Git blobs and verify evidence; no remote or deployment I/O."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
PREFIX = "docs/verification/artifacts/2026-10-11/im-worker-active-lease-deployment/"
BASE = "77ca608c7d98a147a2af4d657c2cb8c82be9e495"
FINAL = sys.argv[1] if len(sys.argv) > 1 else "41e878449186294df9cf14b4236c3561cf470436"
IMAGE = "sha256:abda33f8fe5bb4abca45464a5d300fff8981a8b68908be1b64f6e3ee0d8a0e7f"
TOOLS_SHA = "71a0a7c69a9027d17445d07808dd09e01919b19c61dad06e34dda3d2e6b380ee"
files = {}


def blob(name, ref=FINAL):
    data = subprocess.check_output(["git", "show", ref + ":" + PREFIX + name], cwd=REPO)
    if ref == FINAL:
        files[name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    return data


def load(name):
    return json.loads(blob(name))


frozen = json.loads((HERE / "frozen-inputs.json").read_text(encoding="utf-8"))
for name, identity in frozen["files"].items():
    if name == "README.md":
        continue
    assert hashlib.sha256(blob(name)).hexdigest() == identity["sha256"], name
for name in ("stage_and_prepare.py", "run_candidate_checks.py", "configuration_proof.py", "verify_evidence.py"):
    ast.parse(blob(name), filename=name)
manifest = load("services-manifest.json")
assert manifest["stage"] == "prepared_not_deployed"
roles = manifest["roles"]
assert set(roles) == {"api", "worker"}
assert roles["worker"]["candidate_image"] == IMAGE
assert roles["worker"]["old_image"] == "sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a"
assert roles["api"]["old_image"] == roles["api"]["candidate_image"] == "sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3"
assert roles["api"]["config_hashes"]["candidate"] == roles["api"]["config_hashes"]["rollback"]
spec = load("payload-spec.json")
for role in roles:
    assert roles[role]["files"] == spec["roles"][role][2]
receipt = load("default-runtime-receipt.json")
assert receipt["image"] == IMAGE
assert receipt["manifest_sha256"] == files["services-manifest.json"]["sha256"]
required = {"validate_default_runtime.py", "default_entry_probe.py", "test-tools.zip",
            "tests/test_worker_active_lease.py", "tests/test_published_worker_entrypoint.py",
            "tests/test_worker_claim_fencing.py", "tests/test_worker_lease_window.py"}
assert set(receipt["input_sha256"]) == required
for name, expected in receipt["input_sha256"].items():
    actual = TOOLS_SHA if name == "test-tools.zip" else hashlib.sha256(blob(name)).hexdigest()
    assert actual == expected, name
assert set(receipt["checks"]) == {"default_entry", "default_pytest"}
for check in receipt["checks"].values():
    assert check["exit_code"] == check["cleanup_exit"] == 0
    assert check["stderr"] == ""
    argv = check["argv"]
    assert argv[:2] == ["docker", "run"]
    assert argv[argv.index("--network") + 1] == "none"
    assert "--read-only" in argv and "no-new-privileges" in argv
    assert argv[argv.index("--name") + 1] == check["container"]
    assert IMAGE in argv
    assert not any(arg.startswith("PYTHONPATH=") for arg in argv)
    mounts = [argv[index + 1] for index, arg in enumerate(argv) if arg == "-v"]
    assert all(m.endswith(":ro") and "/im-worker-active-lease-20261011/" in m for m in mounts)
probe = json.loads(receipt["checks"]["default_entry"]["stdout"])
assert probe["result"] == "PASS"
assert probe["source_hashes"] == {row[0]: row[2] for row in roles["worker"]["files"].values()}
assert probe["default_entry_consumer"] == "/usr/local/lib/python3.12/site-packages/app/core/outbox.py"
stdout = receipt["checks"]["default_pytest"]["stdout"]
assert "70 passed, 1 skipped in 2.07s" in stdout
assert "isolated native PostgreSQL lease gate requires explicit test URL" in stdout
protocol = load("protocol-check-output.txt")
expected = {("api", roles["api"]["old_image"]), ("worker", IMAGE), ("worker", roles["worker"]["old_image"])}
assert len(protocol) == 3 and {(p["role"], p["image"]) for p in protocol} == expected
worker_checks = {"worker_runtime_imports", "worker_entry_composition", "worker_event_wiring", "worker_credential_event_boundary",
                 "worker_t2_manual_source_advisory", "worker_refresh_same_result_no_expiry_extension", "worker_refresh_superseded_result",
                 "worker_refresh_mismatched_replay_revokes", "worker_refresh_legacy_rotation"}
for proof in protocol:
    assert proof["passed"] is True and len(proof["checks"]) == 9
    if proof["role"] == "worker":
        assert set(proof["checks"]) == worker_checks and proof["protocol"] == "worker-runtime-refresh-v1"
    else:
        assert proof["protocol"] == "mobile-refresh-recovery-v1"
checks = load("candidate-checks-receipt.json")
assert checks["checks"] == {"default_runtime_exit": 0, "protocol_exit": 0}
assert checks["before_count"] == checks["after_count"] == 60 and checks["exact_container_ids_unchanged"] is True
assert checks["added"] == checks["removed"] == checks["changed"] == []
configuration = load("configuration-proof.json")
assert configuration["roles"]["api"]["fully_identical"] is True
assert configuration["roles"]["worker"]["only_image_may_differ"] is True
for row in configuration["roles"].values():
    assert row["live_id_unchanged"] and row["live_image_unchanged"] and row["running"] and row["health"] == "healthy"
assert configuration["business_release_guard.py"] == "46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b"
assert configuration["business_refresh_image_probe.py"] == "2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15"
running = load("running-containers-after.json")
assert running["running_count"] == len(running["containers"]) == 35
assert hashlib.sha256("\n".join(sorted(running["containers"])).encode()).hexdigest() == running["running_container_id_set_sha256"]
identities = load("deployment-input-identities.json")
assert identities["candidate_image"] == IMAGE and identities["deployed"] is False
for name, expected_sha in identities["files"].items():
    assert hashlib.sha256(blob(name)).hexdigest() == expected_sha, (name, "author Git identity mismatch")
result = {"result": "PASS", "final_author_commit": FINAL, "core_scripts_commit": BASE,
          "candidate_image": IMAGE, "core_and_payloads_unchanged": True,
          "exact_seven_validation_inputs": True, "default_image_tests_passed": 70,
          "default_image_tests_skipped": 1, "skip_reason": "explicit isolated PG URL absent",
          "protocol_images": 3, "all_container_ids_unchanged": 60, "running_containers": 35,
          "reviewer_docker_or_network_operations": 0, "deployed": False, "files": files}
(HERE / "image-evidence-audit.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps({k: v for k, v in result.items() if k != "files"}, indent=2))
