"""Gate source and rebuilt Android APK assets against the Flutter source tree.

Run separately from ABI, signature, alignment and rebuild equivalence checks.
Requires the existing build/verification Python runtime's PyYAML dependency.
"""
import argparse
import hashlib
import json
import math
import re
import struct
from pathlib import Path, PurePosixPath
from zipfile import BadZipFile, ZipFile

import yaml


PREFIX = "assets/flutter_assets/"
REQUIRED_FONTS = {
    "MaterialIcons": "fonts/MaterialIcons-Regular.otf",
    "packages/cupertino_icons/CupertinoIcons": "packages/cupertino_icons/assets/CupertinoIcons.ttf",
}
CATALOGS = ("fluent_emoji_catalog.dart", "fluent_vector_emoji_catalog.dart")


def _asset_name(value: object, *, allow_directory: bool = False) -> str:
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise ValueError(f"invalid Flutter asset path: {value!r}")
    if value.endswith("/") and not allow_directory:
        raise ValueError(f"invalid Flutter asset path for a file: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or str(path) != value.rstrip("/"):
        raise ValueError(f"invalid Flutter asset path: {value!r}")
    return value


def _source_assets(mobile_root: Path, flavor: str) -> dict[str, Path]:
    root = mobile_root.resolve(strict=True)
    pubspec = yaml.safe_load((root / "pubspec.yaml").read_text(encoding="utf-8"))
    declarations = pubspec.get("flutter", {}).get("assets", [])
    if not isinstance(declarations, list) or not declarations:
        raise ValueError("pubspec has no declared Flutter assets")
    assets = {}
    for declaration in declarations:
        if isinstance(declaration, dict):
            if set(declaration) - {"path", "flavors"}:
                raise ValueError("transformed or unsupported pubspec asset declaration")
            flavors = declaration.get("flavors")
            if flavors is not None and flavor not in flavors:
                continue
            declaration = declaration.get("path")
        name = _asset_name(declaration, allow_directory=True)
        source = root / name
        files = sorted(source.iterdir()) if name.endswith("/") else [source]
        if name.endswith("/") and not source.is_dir():
            raise ValueError(f"missing declared source asset directory: {name}")
        # Flutter directory declarations include direct files, not subdirectories.
        for path in files:
            if path.is_dir():
                continue
            if not path.is_file() or not path.stat().st_size:
                raise ValueError(f"missing or empty declared source asset: {name}")
            path.resolve(strict=True).relative_to(root)
            assets[path.relative_to(root).as_posix()] = path
    for filename in CATALOGS:
        text = (root / "lib/features/emoji" / filename).read_text(encoding="utf-8")
        references = re.findall(r"\basset\s*:\s*['\"]([^'\"]+)['\"]", text)
        if not references:
            raise ValueError(f"empty emoji catalog: {filename}")
        for name in references:
            _asset_name(name)
            if name not in assets:
                raise ValueError(f"emoji catalog asset not declared by pubspec: {name}")
    return assets


def _decode_asset_manifest(data: bytes) -> dict:
    """Read Flutter StandardMessageCodec's map/list/string/number manifest format."""
    position = 0

    def take(size):
        nonlocal position
        if size < 0 or position + size > len(data):
            raise ValueError("truncated AssetManifest.bin")
        result = data[position:position + size]
        position += size
        return result

    def size():
        first = take(1)[0]
        if first == 254:
            return struct.unpack("<H", take(2))[0]
        if first == 255:
            return struct.unpack("<I", take(4))[0]
        return first

    def value(depth=0):
        nonlocal position
        if depth > 32:
            raise ValueError("overly nested AssetManifest.bin")
        tag = take(1)[0]
        if tag == 0:
            return None
        if tag in (1, 2):
            return tag == 1
        if tag in (3, 4):
            return struct.unpack("<i" if tag == 3 else "<q", take(4 if tag == 3 else 8))[0]
        if tag == 6:
            take((-position) % 8)
            return struct.unpack("<d", take(8))[0]
        if tag == 7:
            return take(size()).decode("utf-8")
        if tag in (12, 13):
            length = size()
            if length > len(data):
                raise ValueError("invalid AssetManifest.bin collection length")
            if tag == 12:
                return [value(depth + 1) for _ in range(length)]
            result = {}
            for _ in range(length):
                key = value(depth + 1)
                if not isinstance(key, str) or key in result:
                    raise ValueError("invalid or duplicate AssetManifest.bin map key")
                result[key] = value(depth + 1)
            return result
        raise ValueError(f"unsupported AssetManifest.bin value tag: {tag}")

    result = value()
    if position != len(data) or not isinstance(result, dict) or not result:
        raise ValueError("invalid AssetManifest.bin map or trailing bytes")
    return result


def validate_apk(path: Path, mobile_root: Path, flavor: str = "standard") -> dict:
    with ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("duplicate ZIP entries")

        def read(name, description):
            entry = PREFIX + name
            if entry not in names or archive.getinfo(entry).file_size == 0:
                raise ValueError(f"missing or empty {description}: {name}")
            if archive.getinfo(entry).is_dir():
                raise ValueError(f"ZIP directory cannot be a {description} file: {name}")
            return archive.read(entry)

        manifest = _decode_asset_manifest(read("AssetManifest.bin", "AssetManifest.bin"))
        try:
            families = json.loads(read("FontManifest.json", "FontManifest.json"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ValueError("invalid FontManifest.json") from error
        if not isinstance(families, list) or not families:
            raise ValueError("FontManifest.json has no font families")
        font_membership = {}
        for family in families:
            if (not isinstance(family, dict) or not isinstance(family.get("family"), str)
                    or not family["family"] or family["family"] in font_membership
                    or not isinstance(family.get("fonts"), list) or not family["fonts"]):
                raise ValueError("invalid or duplicate FontManifest.json font family")
            fonts = set()
            for font in family["fonts"]:
                if not isinstance(font, dict):
                    raise ValueError("invalid FontManifest.json font entry")
                name = _asset_name(font.get("asset"))
                read(name, "referenced font")
                fonts.add(name)
            font_membership[family["family"]] = fonts
        for family, name in REQUIRED_FONTS.items():
            if name not in font_membership.get(family, set()):
                raise ValueError(f"required icon font absent from FontManifest.json family: {family}")

        manifest_membership = {}
        for name, variants in manifest.items():
            _asset_name(name)
            if not isinstance(variants, list) or not variants:
                raise ValueError(f"invalid AssetManifest.bin variants: {name}")
            variant_assets = set()
            for variant in variants:
                if not isinstance(variant, dict):
                    raise ValueError(f"invalid AssetManifest.bin variant: {name}")
                variant_name = _asset_name(variant.get("asset"))
                dpr = variant.get("dpr")
                if dpr is not None and (type(dpr) not in (int, float) or not math.isfinite(dpr) or dpr <= 0):
                    raise ValueError(f"invalid AssetManifest.bin DPR: {name}")
                read(variant_name, "manifest variant asset")
                variant_assets.add(variant_name)
            manifest_membership[name] = variant_assets

        source_assets = _source_assets(mobile_root, flavor)
        for name, source in source_assets.items():
            bundled = read(name, "source asset")
            if hashlib.sha256(bundled).digest() != hashlib.sha256(source.read_bytes()).digest():
                raise ValueError(f"source asset SHA256 mismatch: {name}")
            if name not in manifest_membership:
                raise ValueError(f"AssetManifest.bin missing declared asset: {name}")
            if name not in manifest_membership[name]:
                raise ValueError(f"AssetManifest.bin omits base asset variant: {name}")

    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "sha256": digest,
        "source_asset_count": len(source_assets),
        "emoji_webp_count": sum(name.startswith("assets/emoji/") and name.endswith(".webp") for name in source_assets),
        "emoji_svg_count": sum(name.startswith("assets/emoji_vector/") and name.endswith(".svg") for name in source_assets),
        "font_count": len(set().union(*font_membership.values())),
        "flavor": flavor,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--mobile-root", type=Path, default=Path(__file__).resolve().parents[1] / "apps/mobile_flutter")
    parser.add_argument("--flavor", default="standard")
    args = parser.parse_args()
    try:
        print(json.dumps(validate_apk(args.apk, args.mobile_root, args.flavor), indent=2))
    except (ValueError, OSError, BadZipFile, UnicodeError, yaml.YAMLError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
