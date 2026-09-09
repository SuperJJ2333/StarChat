"""Apply the pinned patch with full-file hashes and exact, zero-fuzz hunks."""
import argparse
import hashlib
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import re
import shutil

HERE = Path(__file__).resolve().parent


def patched_files(root):
    manifest = json.loads((HERE / "upstream-manifest.json").read_text(encoding="utf-8"))
    lines = (HERE / "patches/0001-cross-user-media-dedup.patch").read_text(encoding="utf-8").splitlines(True)
    results = {}
    index = 0
    while index < len(lines):
        if not lines[index].startswith("--- a/"):
            raise ValueError("Unexpected patch header")
        relative = lines[index][6:].strip()
        if relative not in manifest["files"] or lines[index + 1].strip() != "+++ b/" + relative:
            raise ValueError("Unapproved patch path")
        original = (root / relative).read_text(encoding="utf-8")
        hashes = manifest["files"][relative]
        if hashlib.sha256(original.encode()).hexdigest() != hashes["before"]:
            raise ValueError("Upstream source does not match Synapse 1.132.0: " + relative)
        source = original.splitlines(True)
        output, cursor = [], 0
        index += 2
        while index < len(lines) and not lines[index].startswith("--- a/"):
            match = re.match(r"@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@", lines[index])
            if not match:
                raise ValueError("Invalid patch hunk")
            start = int(match[1]) - 1
            if start < cursor:
                raise ValueError("Overlapping patch hunks")
            output.extend(source[cursor:start])
            cursor = start
            index += 1
            while index < len(lines) and not lines[index].startswith(("@@ ", "--- a/")):
                line = lines[index]
                if line[0] in " -":
                    if cursor >= len(source) or source[cursor] != line[1:]:
                        raise ValueError("Patch context mismatch")
                    cursor += 1
                if line[0] in " +":
                    output.append(line[1:])
                elif line[0] != "-":
                    raise ValueError("Unexpected patch operation")
                index += 1
        output.extend(source[cursor:])
        result = "".join(output)
        if hashlib.sha256(result.encode()).hexdigest() != hashes["after"]:
            raise ValueError("Patched source checksum mismatch")
        results[relative] = result
    if set(results) != set(manifest["files"]):
        raise ValueError("Incomplete patch")
    return results


def apply(root):
    # Validate every file before making any mutation.
    results = patched_files(root)
    for relative, content in results.items():
        (root / relative).write_text(content, encoding="utf-8", newline="\n")
    shutil.copyfile(HERE / "chatflow_media_dedup.py", root / "synapse/media/chatflow_media_dedup.py")
    shutil.copyfile(HERE / "99_chatflow_media.sql", root / "synapse/storage/schema/main/delta/92/99_chatflow_media.sql")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    if args.root is None:
        if importlib.metadata.version("matrix-synapse") != "1.132.0":
            raise SystemExit("Expected installed matrix-synapse 1.132.0")
        args.root = Path(importlib.util.find_spec("synapse").origin).parent.parent
    apply(args.root)
    print("Applied ChatFlow media patch: all upstream and result hashes verified")
