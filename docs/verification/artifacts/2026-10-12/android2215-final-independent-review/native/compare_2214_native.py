"""Read-only APK/native delta receipt; writes only a new sibling JSON report."""
import importlib.util
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def main():
    old_tools, old_apk, report_path, output = map(Path, sys.argv[1:])
    if output.parent.resolve() != Path(__file__).resolve().parent or output.exists():
        raise ValueError("output must be a new sibling evidence file")
    spec = importlib.util.spec_from_file_location("reviewed_inspector", old_tools / "inspect_native.py")
    parser = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(parser)
    old_report_path = old_tools / "native-static-final.json"
    old_readelf_path = old_tools / "readelf-final" / "result.json"
    new_readelf_path = output.parent / "readelf" / "result.json"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    old_report = json.loads(old_report_path.read_text(encoding="utf-8"))
    old_readelf = json.loads(old_readelf_path.read_text(encoding="utf-8"))
    new_readelf = json.loads(new_readelf_path.read_text(encoding="utf-8"))
    inputs = [Path(__file__), old_tools / "inspect_native.py", old_apk,
              report_path, old_report_path, old_readelf_path, new_readelf_path,
              Path(report["source"]["path"]), Path(report["final"]["path"])]
    before = [parser.file_identity(path) for path in inputs]
    started = datetime.now(timezone.utc).isoformat()
    if before[2]["sha256"] != "575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614":
        raise ValueError("unexpected actual 2214 final APK")
    if before[-1]["sha256"] != "4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6":
        raise ValueError("unexpected actual 2215 final APK")
    if before[-2]["sha256"] != "25a6f85774dd5011fc78d675c3958e4168aeed46d3a1bddf2131f943e0387918":
        raise ValueError("unexpected actual 2215 source APK")
    old_actual = parser.inspect_apk(old_apk)
    for key in ("sha256", "bytes"):
        if old_actual[key] != old_report["final"][key]:
            raise ValueError("old static report does not bind actual 2214 APK")
        if before[-1][key] != report["final"][key] or before[-2][key] != report["source"][key]:
            raise ValueError("new static report does not bind actual APKs")
    if old_actual["libraries"] != old_report["final"]["libraries"]:
        raise ValueError("old full native static report differs from actual 2214 APK")
    previous, current = old_actual["libraries"], report["final"]["libraries"]
    if len(current) != 14 or set(previous) != set(current) or set(current) != set(report["source"]["libraries"]):
        raise ValueError("native inventory drift")
    for libraries, crosscheck in ((previous, old_readelf), (current, new_readelf)):
        if crosscheck["pass"] is not True or set(crosscheck["libraries"]) != set(libraries):
            raise ValueError("readelf result inventory incomplete")
        for name, item in libraries.items():
            for typ, field in (("LOAD", "loads"), ("GNU_RELRO", "relro")):
                expected = [{key: segment[key] for key in ("offset", "vaddr", "filesz", "memsz", "align")}
                            for segment in item["elf"][field]]
                if crosscheck["libraries"][name][typ] != expected:
                    raise ValueError("readelf geometry mismatch: " + name)
    rows = []
    for name in sorted(current):
        old, new = previous[name], current[name]
        source = report["source"]["libraries"][name]
        if new["sha256"] != source["sha256"] or new["bytes"] != source["bytes"]:
            raise ValueError("source/final native bytes differ: " + name)
        rows.append({"path": name, "old_sha256": old["sha256"], "new_sha256": new["sha256"],
                     "old_bytes": old["bytes"], "new_bytes": new["bytes"],
                     "byte_identical_to_2214": old["sha256"] == new["sha256"],
                     "source_final_bytes_identical": True,
                     "old_zip": old["zip"], "new_zip": new["zip"],
                     "load_geometry_identical_to_2214": old["elf"]["loads"] == new["elf"]["loads"],
                     "relro_geometry_identical_to_2214": old["elf"]["relro"] == new["elf"]["relro"],
                     "old_loads": old["elf"]["loads"], "new_loads": new["elf"]["loads"],
                     "old_relro": old["elf"]["relro"], "new_relro": new["elf"]["relro"]})
    changed = [row["path"] for row in rows if not row["byte_identical_to_2214"]]
    if changed != ["lib/arm64-v8a/libapp.so"]:
        raise ValueError("unexpected non-application native delta")
    if old_report["matrix_symbols"] != report["matrix_symbols"]:
        raise ValueError("Matrix native symbol contract drift")
    after = [parser.file_identity(path) for path in inputs]
    if before != after:
        raise ValueError("inspection input changed")
    result = {"started_utc": started, "ended_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "Read-only native delta and existing report closure; no build/signing/device acceptance",
              "inputs_before": before, "inputs_after": after, "inputs_unchanged": True,
              "old_static_report_matches_actual_2214_all_native_fields": True,
              "old_and_new_readelf_geometry_matches": True,
              "matrix_symbol_contract_identical_to_2214": True,
              "native_library_count": len(rows), "changed_native_libraries": changed,
              "unchanged_native_library_count": len(rows) - len(changed),
              "new_static_16k_checks_pass": report["static_16k_checks_pass"],
              "runtime_16k_verified": False, "libraries": rows}
    with output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(json.dumps({"native_library_count": len(rows), "changed": changed,
                      "old_static_report_matches_actual": True,
                      "old_and_new_readelf_geometry_matches": True, "inputs_unchanged": True}, indent=2))


if __name__ == "__main__":
    main()
