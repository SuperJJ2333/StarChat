"""Verify the historical aggregate relabel without reading raw logs."""

import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
original_path = HERE.parent / "im-runtime-sampling/runtime-sample.json"
original = json.loads(original_path.read_text(encoding="utf-8"))
corrected = json.loads(
    (HERE / "runtime-sample-corrected.json").read_text(encoding="utf-8")
)
assert (
    corrected["correction"]["original_sample_sha256"].lower()
    == hashlib.sha256(original_path.read_bytes()).hexdigest()
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
print("Four service rows: exact aggregate relabel; all denominators conserved.")
