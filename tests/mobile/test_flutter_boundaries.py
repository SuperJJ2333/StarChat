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


def test_business_pages_use_the_modern_action_system():
    feature_root = ROOT / "apps/mobile_flutter/lib/features"
    offenders = []
    for path in feature_root.rglob("*.dart"):
        source = path.read_text(encoding="utf-8")
        if "WeChatPrimaryButton" in source or "CupertinoButton.filled" in source:
            offenders.append(path.relative_to(ROOT).as_posix())
    assert offenders == []


def test_video_call_page_renders_local_and_remote_webrtc_streams():
    source = (
        ROOT / "apps/mobile_flutter/lib/features/matrix/call_page.dart"
    ).read_text(encoding="utf-8")
    assert source.count("RTCVideoView(") >= 2
    assert "remoteMediaStream" in source
    assert "localMediaStream" in source


def test_video_call_surface_uses_flexible_height_on_compact_devices():
    source = (
        ROOT / "apps/mobile_flutter/lib/features/matrix/call_page.dart"
    ).read_text(encoding="utf-8")
    video_branch = source[source.index("if (state.type == CallMediaType.video") :]
    assert "Expanded(" in video_branch[:500]
    assert "maxHeight: 360" in video_branch[:900]
