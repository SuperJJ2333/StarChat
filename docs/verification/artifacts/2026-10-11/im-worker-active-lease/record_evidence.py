"""Record exact non-sensitive source/log identities for independent review."""
import hashlib
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import psycopg
import sqlalchemy

root = Path(__file__).resolve().parents[5]
artifact = Path(__file__).resolve().parent
sources = [
    "services/business-worker/app/worker.py", "services/business-worker/app/main.py",
    "services/business-worker/app/lease_renewal.py", "services/business-api/app/core/outbox.py",
]
tests = [
    "tests/business_worker/test_worker_active_lease.py",
    "tests/business_worker/test_worker_active_lease_postgres.py",
    "tests/business_worker/test_published_worker_entrypoint.py",
    "tests/business_worker/test_worker_lease_window.py",
    "tests/business_worker/test_reserve_monitor_runner.py",
    "tests/business_worker/test_wallet_operations_wiring.py",
]
def identity(relative):
    path = root / relative
    data = path.read_bytes()
    return {"path": relative, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}

results = {
    "baseline.log": {"exit": 1, "passed": 307, "skipped": 12, "xfailed": 1, "failed": 1},
    "active-red.log": {"exit": 1, "failed": 1},
    "active-green.log": {"exit": 0, "passed": 1},
    "lifecycle-green.log": {"exit": 0, "passed": 13},
    "pg-contract-red.log": {"exit": 1, "failed": 3},
    "pg-contract-green.log": {"exit": 0, "passed": 16},
    "budget-red.log": {"exit": 1, "failed": 4, "passed": 1, "warning": 1},
    "default-entry-negative-control.log": {"exit": 1, "failed": 1},
    "default-entry-green.log": {"exit": 0, "passed": 2},
    "impact-first.log": {"exit": 1, "passed": 339, "skipped": 1, "failed": 2},
    "impact-green.log": {"exit": 0, "passed": 342, "skipped": 1},
}
test_prefix = "py -3.12 -m pytest -q -p no:cacheprovider "
impact = ("tests/business_worker tests/business_api/test_outbox.py "
          "tests/business_api/test_outbox_handover.py tests/business_api/audit/test_outbox_publication_receipts.py")
commands = {
    "baseline.log": test_prefix + impact,
    "active-red.log": test_prefix + tests[0],
    "active-green.log": test_prefix + tests[0],
    "lifecycle-green.log": test_prefix + tests[0],
    "pg-contract-red.log": test_prefix + tests[1],
    "pg-contract-green.log": test_prefix + tests[0] + " " + tests[1],
    "budget-red.log": test_prefix + tests[0] + " -k 'aborted or nonfinite'",
    "default-entry-negative-control.log": test_prefix + tests[2] + " -k actual_main",
    "default-entry-green.log": test_prefix + tests[2],
    "impact-first.log": test_prefix + impact + " --ignore=tests/business_worker/test_support_recovery_compatibility.py",
    "impact-green.log": test_prefix + impact + " --ignore=tests/business_worker/test_support_recovery_compatibility.py",
}
manifest = {
    "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
    "base_commit": "5988deb48185f4f2fb0743615f17ccea597671ce",
    "branch": subprocess.check_output(["git", "branch", "--show-current"], cwd=root, text=True).strip(),
    "production_operations": "none", "independent_review": "pending",
    "platform": platform.platform(), "python": platform.python_version(),
    "sqlalchemy": sqlalchemy.__version__, "psycopg": psycopg.__version__,
    "postgresql": "18.3 native Windows, loopback synthetic UTF8 fixture only",
    "sources": [identity(p) for p in sources], "tests": [identity(p) for p in tests],
    "dependencies": [identity("services/business-api/requirements.lock"),
                     identity("services/business-api/pyproject.toml")],
    "evidence": [{**identity(str((artifact / name).relative_to(root)).replace("\\", "/")),
                  **result, "command": commands[name]} for name, result in results.items()],
    "notes": [
        "Final impact log is bound to all final source/test identities above; earlier logs describe incremental phases in README.",
        "Baseline is unchanged base; old-main negative control loads git-show base main ahead of worker PYTHONPATH.",
        "Initial SQL_ASCII fixture and incomplete receipt test payload were corrected; neither is claimed as behavioral RED.",
        "Full verify.ps1 and production/container gates are not claimed executed. Independent review pending.",
    ],
}
(artifact / "input-identities.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print("Recorded four production source identities and final impact evidence.")
