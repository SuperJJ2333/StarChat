"""Export reviewed Git blobs without importing or running release scripts."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
AUTHOR = "77ca608c7d98a147a2af4d657c2cb8c82be9e495"
DIRECTORY = "docs/verification/artifacts/2026-10-11/im-worker-active-lease-deployment"
DEST = HERE / "frozen"
DEST.mkdir(exist_ok=True)
paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", AUTHOR, "--", DIRECTORY], cwd=REPO, text=True).splitlines()
assert paths
files = {}
for path in paths:
    relative = path.removeprefix(DIRECTORY + "/")
    data = subprocess.check_output(["git", "show", AUTHOR + ":" + path], cwd=REPO)
    target = DEST / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    files[relative] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
identity = {"author_commit": AUTHOR, "directory": DIRECTORY, "files": files}
(HERE / "frozen-inputs.json").write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"author_commit": AUTHOR, "files": len(files), "deploy": files["deploy.py"]}, indent=2))
