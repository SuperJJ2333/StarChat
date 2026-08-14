from pathlib import Path
ROOT = Path(__file__).parents[2]
def test_flutter_client_declares_e2ee_boundary():
    source = (ROOT / "apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart").read_text(encoding="utf-8")
    assert "business API" in source and "sendEncryptedText" in source and "recovery keys" in source
def test_flutter_client_uses_secure_session_storage():
    source = (ROOT / "apps/mobile_flutter/lib/core/session_store.dart").read_text(encoding="utf-8")
    assert "FlutterSecureStorage" in source and "access_token" in source and "refresh_token" in source


def test_flutter_client_packages_native_e2ee_libraries():
    pubspec = (ROOT / "apps/mobile_flutter/pubspec.yaml").read_text(encoding="utf-8")
    assert "flutter_olm:" in pubspec
    assert "flutter_openssl_crypto:" in pubspec
