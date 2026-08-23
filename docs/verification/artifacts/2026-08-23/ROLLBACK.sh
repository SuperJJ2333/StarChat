#!/usr/bin/env python3
"""Restore the baseline registry to an isolated rollback target."""
from pathlib import Path
import json

root = Path(__file__).resolve().parent
source = root / "ORIGINAL_FILE.json"
target = root / "rollback-target.json"
target.write_bytes(source.read_bytes())
registry = json.loads(target.read_text(encoding="utf-8-sig"))
assert "brand" not in registry
print("rollback registry restored: no brand field")
