"""Check the actual APK contents, not its filename or Flutter target flag.

Run in addition to apksigner, aapt and zipalign verification after rebuilding.
"""
import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile


def validate_apk(path: Path, abi: str) -> dict:
    with ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("duplicate ZIP entries")
        abis = sorted({name.split("/")[1] for name in names if name.startswith("lib/") and name.endswith(".so")})
        if abis != [abi]:
            raise ValueError(f"unexpected ABI set: {abis}; expected {[abi]}")
        for library in ("libapp.so", "libflutter.so"):
            if f"lib/{abi}/{library}" not in names:
                raise ValueError(f"missing release library: {library}")
        if "assets/flutter_assets/kernel_blob.bin" in names:
            raise ValueError("debug Dart kernel found in release artifact")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"abis": abis, "size_bytes": path.stat().st_size, "sha256": digest}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--abi", default="arm64-v8a")
    args = parser.parse_args()
    print(json.dumps(validate_apk(args.apk, args.abi), indent=2))
