"""Independent NDK program-header comparison via stdin; no extracted binaries."""
import argparse
import json
import subprocess
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from inspect_native import file_identity


def run(report_path, readelf, output_dir):
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if output_dir.exists():
        raise ValueError("preserve prior cross-check output")
    output_dir.mkdir()
    result = {"started_utc": datetime.now(timezone.utc).isoformat(),
              "report": file_identity(report_path),
              "tool": file_identity(readelf), "libraries": {}}
    with zipfile.ZipFile(report["final"]["path"]) as archive:
        for name, expected in report["final"]["libraries"].items():
            payload = archive.read(name)
            proc = subprocess.run([str(readelf), "-Wl", "-"], input=payload,
                                  capture_output=True, timeout=30, check=True)
            text = proc.stdout.decode("utf-8")
            (output_dir / (Path(name).name + ".readelf.txt")).write_text(
                text, encoding="utf-8")
            actual = {"LOAD": [], "GNU_RELRO": []}
            for line in text.splitlines():
                parts = line.split()
                if parts and parts[0] in actual:
                    actual[parts[0]].append(dict(zip(
                        ("offset", "vaddr", "filesz", "memsz", "align"),
                        [int(parts[n], 16) for n in (1, 2, 4, 5, -1)])))
            wanted = {
                typ: [{field: p[field] for field in
                       ("offset", "vaddr", "filesz", "memsz", "align")}
                      for p in expected["elf"][field_name]]
                for typ, field_name in (("LOAD", "loads"), ("GNU_RELRO", "relro"))}
            if actual != wanted:
                raise ValueError("readelf program-header mismatch: " + name)
            result["libraries"][name] = {"matches": True, **actual}
        crypto = archive.read("lib/arm64-v8a/libcrypto.so")
        dynamic = subprocess.run([str(readelf), "-Wd", "-"], input=crypto,
                                 capture_output=True, timeout=30, check=True)
        (output_dir / "libcrypto.dynamic.txt").write_bytes(dynamic.stdout)
        symbols = subprocess.run([str(readelf), "--dyn-syms", "--wide", "-"],
                                 input=crypto, capture_output=True,
                                 timeout=30, check=True).stdout.decode("utf-8")
        required = set(report["matrix_symbols"]["required"])
        required.update(report["matrix_symbols"]["size_fallback_exported"])
        selected, found = [], set()
        for line in symbols.splitlines():
            parts = line.split()
            if len(parts) < 8:
                continue
            label = parts[7].split("@", 1)[0]
            if label in required:
                selected.append(line)
                if parts[3] in ("FUNC", "IFUNC") and parts[4] in ("GLOBAL", "WEAK") and parts[6] != "UND":
                    found.add(label)
        if found != required:
            raise ValueError("readelf required function exports mismatch")
        (output_dir / "libcrypto.required-symbols.txt").write_text(
            "\n".join(selected) + "\n", encoding="utf-8")
        result["required_function_exports_confirmed"] = sorted(found)
    if file_identity(Path(report["final"]["path"])) != {
            key: report["final"][key] for key in ("path", "bytes", "sha256")}:
        raise ValueError("final APK changed")
    result["ended_utc"] = datetime.now(timezone.utc).isoformat()
    result["pass"] = True
    (output_dir / "result.json").write_text(
        json.dumps(result, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("readelf", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    run(args.report, args.readelf, args.output_dir)
