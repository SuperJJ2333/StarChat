"""Record staged Git evidence identity separately from checkout bytes."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
PREFIX = HERE.relative_to(REPO).as_posix() + "/"
paths = subprocess.check_output(["git", "diff", "--cached", "--name-only"], cwd=REPO, text=True).splitlines()
assert paths and all(path.startswith(PREFIX) for path in paths), "unrelated staged edits"
rows = {}
for path in paths:
    name = path.removeprefix(PREFIX)
    if name == "review-identities.json":
        continue
    data = subprocess.check_output(["git", "show", ":" + path], cwd=REPO)
    raw = (REPO / path).read_bytes()
    if path.endswith(".py"):
        ast.parse(data, filename=path)
    rows[name] = {"git_blob_sha256": hashlib.sha256(data).hexdigest(), "git_blob_bytes": len(data),
                  "checkout_raw_sha256": hashlib.sha256(raw).hexdigest(), "checkout_raw_bytes": len(raw)}
result = {"recorded_utc": datetime.now(timezone.utc).isoformat(), "identity_domain": "staged Git blobs; checkout raw hashes separately labeled",
          "files": rows}
(HERE / "review-identities.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"git_bound_files": len(rows), "python_ast": "PASS"}))
