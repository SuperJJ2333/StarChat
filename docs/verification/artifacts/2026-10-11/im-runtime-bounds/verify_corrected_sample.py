"""Verify the historical aggregate relabel without reading raw logs."""

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
original_path = HERE.parent / "im-runtime-sampling/runtime-sample.json"
original_bytes = original_path.read_bytes()
original = json.loads(original_bytes)
corrected = json.loads(
    (HERE / "runtime-sample-corrected.json").read_text(encoding="utf-8")
)
identity = corrected["correction"]
workspace_hash = identity["original_workspace_bytes_sha256"].lower()
archive_hash = identity["original_git_blob_bytes_sha256"].lower()
# Git stores LF while the original Windows observation file used CRLF.
# Accept only those two exact identities, then prove they differ solely by
# line endings. Never rewrite the original historical evidence to pass a hash.
assert hashlib.sha256(original_bytes).hexdigest() in {workspace_hash, archive_hash}
archive_bytes = original_bytes.replace(b"\r\n", b"\n")
assert hashlib.sha256(archive_bytes).hexdigest() == archive_hash
assert (
    hashlib.sha256(archive_bytes.replace(b"\n", b"\r\n")).hexdigest() == workspace_hash
)
assert corrected["schema"] == 2
for field in ("since_utc", "until_utc", "observed_utc", "window_seconds", "limits"):
    assert corrected[field] == original[field]
for old_row, new_row in zip(original["services"], corrected["services"], strict=True):
    expected = json.loads(json.dumps(old_row))
    counts = expected["logs"]["summary"]
    counts["long_sync_30s_zero_db_fetch_candidates"] = counts.pop(
        "idle_sync_30s_completed"
    )
    assert new_row == expected
    assert sum(counts["line_buckets"].values()) == counts["log_lines"]
    assert sum(counts["http_buckets"].values()) == counts["http_completed"]
    assert counts["started_request_records"] == (
        counts["completed_with_observed_start"]
        + counts["started_without_observed_completion"]
    )
    assert counts["http_completed"] == (
        counts["completed_with_observed_start"]
        + counts["completed_without_observed_start"]
    )
print(
    "LF/CRLF identities verified; four exact aggregate relabels; all denominators conserved."
)
