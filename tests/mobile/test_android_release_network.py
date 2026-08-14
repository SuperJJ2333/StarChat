from pathlib import Path
import xml.etree.ElementTree as ET


ANDROID = "http://schemas.android.com/apk/res/android"


def test_release_manifest_allows_local_api_network_access():
    manifest = Path("apps/mobile_flutter/android/app/src/main/AndroidManifest.xml")
    root = ET.parse(manifest).getroot()
    permissions = {
        node.attrib.get(f"{{{ANDROID}}}name") for node in root.findall("uses-permission")
    }
    assert "android.permission.INTERNET" in permissions
    application = root.find("application")
    assert application is not None
    assert application.attrib.get(f"{{{ANDROID}}}usesCleartextTraffic") == "true"
