"""Reject APKs whose Dart payload works but their app asset bundle is incomplete."""
import importlib.util
import json
import struct
from pathlib import Path
from zipfile import ZipFile

import pytest


ROOT = Path(__file__).resolve().parents[2]
PREFIX = "assets/flutter_assets/"
FONTS = [
    {"family": "MaterialIcons", "fonts": [{"asset": "fonts/MaterialIcons-Regular.otf"}]},
    {"family": "packages/cupertino_icons/CupertinoIcons", "fonts": [
        {"asset": "packages/cupertino_icons/assets/CupertinoIcons.ttf"}
    ]},
]


def validator():
    path = ROOT / "scripts/verify_android_flutter_assets.py"
    assert path.exists(), "Android delivery has no Flutter asset completeness gate"
    spec = importlib.util.spec_from_file_location("flutter_asset_gate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.validate_apk


def codec(value):
    """Hand-built StandardMessageCodec fixture, independent of the validator."""
    if isinstance(value, str):
        data = value.encode("utf-8")
        size = bytes([len(data)]) if len(data) < 254 else b"\xfe" + struct.pack("<H", len(data))
        return b"\x07" + size + data
    if isinstance(value, list):
        return b"\x0c" + bytes([len(value)]) + b"".join(codec(v) for v in value)
    if isinstance(value, dict):
        return b"\x0d" + bytes([len(value)]) + b"".join(codec(k) + codec(v) for k, v in value.items())
    raise AssertionError("unsupported test fixture value")


@pytest.fixture
def bundle(tmp_path):
    mobile = tmp_path / "mobile"
    source = {
        "assets/emoji/smile.webp": b"animated-webp-fixture",
        "assets/emoji_vector/smile.svg": b"<svg>vector-fixture</svg>",
        "assets/branding/logo.png": b"branding-fixture",
    }
    for name, content in source.items():
        path = mobile / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    (mobile / "pubspec.yaml").write_text(
        "name: fixture\nflutter:\n  uses-material-design: true\n  assets:\n"
        "    - assets/emoji/\n    - assets/emoji_vector/\n    - assets/branding/\n",
        encoding="utf-8",
    )
    catalog = mobile / "lib/features/emoji"
    catalog.mkdir(parents=True)
    for filename, asset in [
        ("fluent_emoji_catalog.dart", "assets/emoji/smile.webp"),
        ("fluent_vector_emoji_catalog.dart", "assets/emoji_vector/smile.svg"),
    ]:
        (catalog / filename).write_text(f"const emoji = [Emoji(asset: '{asset}')];\n", encoding="utf-8")
    entries = {PREFIX + name: content for name, content in source.items()}
    entries.update({
        PREFIX + "kernel_blob.bin": b"debug-kernel",
        PREFIX + "AssetManifest.bin": codec({name: [{"asset": name}] for name in source}),
        PREFIX + "FontManifest.json": json.dumps(FONTS).encode(),
        PREFIX + "fonts/MaterialIcons-Regular.otf": b"material-font",
        PREFIX + "packages/cupertino_icons/assets/CupertinoIcons.ttf": b"cupertino-font",
    })
    return mobile, entries, tmp_path / "fixture.apk"


def check(bundle):
    mobile, entries, apk = bundle
    with ZipFile(apk, "w") as archive:
        for name, content in entries.items():
            archive.writestr(name, content)
    return validator()(apk, mobile)


def test_accepts_complete_manifest_fonts_and_source_asset_hashes(bundle):
    result = check(bundle)
    assert result["source_asset_count"] == 3
    assert result["emoji_webp_count"] == 1
    assert result["emoji_svg_count"] == 1
    assert result["font_count"] == 2


def test_rejects_snapshot_only_apk_as_missing_app_bundle(bundle):
    bundle[1].clear()
    bundle[1][PREFIX + "kernel_blob.bin"] = b"debug-kernel"
    with pytest.raises(ValueError, match="AssetManifest.bin"):
        check(bundle)


@pytest.mark.parametrize("name", ["AssetManifest.bin", "FontManifest.json"])
def test_rejects_empty_manifest(bundle, name):
    bundle[1][PREFIX + name] = b""
    with pytest.raises(ValueError, match=name):
        check(bundle)


@pytest.mark.parametrize("font", ["fonts/MaterialIcons-Regular.otf", "packages/cupertino_icons/assets/CupertinoIcons.ttf"])
def test_rejects_missing_referenced_icon_font(bundle, font):
    del bundle[1][PREFIX + font]
    with pytest.raises(ValueError, match="font"):
        check(bundle)


def test_rejects_empty_referenced_icon_font(bundle):
    bundle[1][PREFIX + "fonts/MaterialIcons-Regular.otf"] = b""
    with pytest.raises(ValueError, match="font"):
        check(bundle)


def test_rejects_font_file_absent_from_its_required_family(bundle):
    bundle[1][PREFIX + "FontManifest.json"] = json.dumps(FONTS[1:]).encode()
    with pytest.raises(ValueError, match="MaterialIcons"):
        check(bundle)


def test_rejects_missing_catalog_emoji(bundle):
    del bundle[1][PREFIX + "assets/emoji/smile.webp"]
    with pytest.raises(ValueError, match="missing.*asset"):
        check(bundle)


def test_rejects_asset_bytes_that_differ_from_source(bundle):
    bundle[1][PREFIX + "assets/emoji_vector/smile.svg"] = b"damaged"
    with pytest.raises(ValueError, match="SHA256.*smile.svg"):
        check(bundle)


def test_rejects_asset_manifest_without_declared_emoji_membership(bundle):
    bundle[1][PREFIX + "AssetManifest.bin"] = codec({
        "assets/branding/logo.png": [{"asset": "assets/branding/logo.png"}]
    })
    with pytest.raises(ValueError, match="AssetManifest.*assets/emoji"):
        check(bundle)


def test_rejects_malformed_binary_asset_manifest(bundle):
    bundle[1][PREFIX + "AssetManifest.bin"] = b"broken"
    with pytest.raises(ValueError, match="AssetManifest"):
        check(bundle)


def test_rejects_catalog_asset_removed_from_pubspec(bundle):
    path = bundle[0] / "pubspec.yaml"
    path.write_text(path.read_text(encoding="utf-8").replace("    - assets/emoji/\n", ""), encoding="utf-8")
    with pytest.raises(ValueError, match="catalog.*not declared"):
        check(bundle)


def test_rejects_nonempty_manifest_with_no_font_families(bundle):
    bundle[1][PREFIX + "FontManifest.json"] = b"[]"
    with pytest.raises(ValueError, match="font.*famil"):
        check(bundle)


def additional_manifest_entry(bundle, name, variant_name=None):
    names = ["assets/emoji/smile.webp", "assets/emoji_vector/smile.svg", "assets/branding/logo.png"]
    manifest = {asset: [{"asset": asset}] for asset in names}
    manifest[name] = [{"asset": variant_name or name}]
    bundle[1][PREFIX + "AssetManifest.bin"] = codec(manifest)


@pytest.mark.parametrize("content", [None, b""])
def test_rejects_missing_or_empty_additional_package_manifest_asset(bundle, content):
    name = "packages/fixture/missing.svg"
    additional_manifest_entry(bundle, name)
    if content is not None:
        bundle[1][PREFIX + name] = content
    with pytest.raises(ValueError, match="manifest.*asset"):
        check(bundle)


def test_rejects_additional_package_manifest_key_with_invalid_path(bundle):
    name = "../outside.svg"
    additional_manifest_entry(bundle, name)
    bundle[1][PREFIX + name] = b"present-but-invalid-path"
    with pytest.raises(ValueError, match="invalid Flutter asset path"):
        check(bundle)


def test_rejects_absent_variant_of_additional_package_asset(bundle):
    name = "packages/fixture/logo.svg"
    additional_manifest_entry(bundle, name, "packages/fixture/2.0x/logo.svg")
    bundle[1][PREFIX + name] = b"package-base-fixture"
    with pytest.raises(ValueError, match="manifest.*asset"):
        check(bundle)


def test_accepts_additional_bundled_package_asset_without_app_source_hash(bundle):
    name = "packages/fixture/logo.svg"
    additional_manifest_entry(bundle, name)
    bundle[1][PREFIX + name] = b"package-asset-with-no-app-source-counterpart"
    assert check(bundle)["source_asset_count"] == 3


def test_accepts_package_logical_asset_with_only_bundled_resolution_variant(bundle):
    name = "packages/fixture/logo.png"
    variant = "packages/fixture/2.0x/logo.png"
    additional_manifest_entry(bundle, name, variant)
    bundle[1][PREFIX + variant] = b"package-resolution-variant"
    assert check(bundle)["source_asset_count"] == 3


def test_rejects_nonempty_zip_directory_as_manifest_variant_file(bundle):
    name = "packages/fixture/logo.svg"
    directory = "packages/fixture/not-a-file/"
    additional_manifest_entry(bundle, name, directory)
    bundle[1][PREFIX + directory] = b"nonempty-directory-payload"
    with pytest.raises(ValueError, match="directory|invalid Flutter asset path"):
        check(bundle)


def test_rejects_nonempty_zip_directory_as_referenced_font_file(bundle):
    directory = "packages/fixture/not-a-font/"
    fonts = FONTS + [{"family": "ExtraFixture", "fonts": [{"asset": directory}]}]
    bundle[1][PREFIX + "FontManifest.json"] = json.dumps(fonts).encode()
    bundle[1][PREFIX + directory] = b"nonempty-directory-payload"
    with pytest.raises(ValueError, match="directory|invalid Flutter asset path"):
        check(bundle)
