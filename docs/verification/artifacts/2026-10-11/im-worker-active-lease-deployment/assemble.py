"""Generate exact Git-byte overlay/test payloads; no network or deployment."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
SOURCE = "c3dd314212c73414c5ab371b4363e077bc9104c2"
BASE = "5988deb48185f4f2fb0743615f17ccea597671ce"
TARGETS = {
    "main.py": ("services/business-worker/app/main.py", "/opt/business-worker/app/main.py"),
    "worker.py": ("services/business-worker/app/worker.py", "/opt/business-worker/app/worker.py"),
    "lease_renewal.py": ("services/business-worker/app/lease_renewal.py", "/opt/business-worker/app/lease_renewal.py"),
    "outbox.py": ("services/business-api/app/core/outbox.py", "/usr/local/lib/python3.12/site-packages/app/core/outbox.py"),
    "outbox-source.py": ("services/business-api/app/core/outbox.py", "/opt/business-api/app/core/outbox.py"),
}

def blob(ref, path):
    return subprocess.check_output(["git", "show", ref + ":" + path], cwd=REPO)

files = {}
(HERE / "worker").mkdir(exist_ok=True)
for filename, (source, target) in TARGETS.items():
    content = blob(SOURCE, source)
    (HERE / "worker" / filename).write_bytes(content)
    old = "ABSENT" if filename == "lease_renewal.py" else hashlib.sha256(blob(BASE, source)).hexdigest()
    files[filename] = (target, old, hashlib.sha256(content).hexdigest())
(HERE / "tests").mkdir(exist_ok=True)
for filename in ("test_worker_active_lease.py", "test_published_worker_entrypoint.py",
                 "test_worker_claim_fencing.py", "test_worker_lease_window.py"):
    (HERE / "tests" / filename).write_bytes(blob(SOURCE, "tests/business_worker/" + filename))
specs = {
    "api": ["starchat-business-api-1", "sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3", {}],
    "worker": ["starchat-business-worker-1", "sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a", files],
}
(HERE / "payload-spec.json").write_text(json.dumps({"source": SOURCE, "base": BASE, "roles": specs}, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"source": SOURCE, "destinations": files}, indent=2))
