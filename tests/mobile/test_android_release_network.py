from pathlib import Path
import xml.etree.ElementTree as ET


ANDROID = "http://schemas.android.com/apk/res/android"


def test_release_disables_cleartext_while_debug_allows_local_api_network_access():
    manifest = Path("apps/mobile_flutter/android/app/src/main/AndroidManifest.xml")
    root = ET.parse(manifest).getroot()
    permissions = {
        node.attrib.get(f"{{{ANDROID}}}name") for node in root.findall("uses-permission")
    }
    assert "android.permission.INTERNET" in permissions
    assert "android.permission.ACCESS_NETWORK_STATE" in permissions
    # 相册媒体选择器必须能读到视频：Android 13+ 图片/视频权限分离，
    # 缺少 READ_MEDIA_VIDEO 时系统只授予图片，选择器看不到任何视频文件。
    assert "android.permission.READ_MEDIA_IMAGES" in permissions
    assert "android.permission.READ_MEDIA_VIDEO" in permissions
    application = root.find("application")
    assert application is not None
    assert application.attrib.get(f"{{{ANDROID}}}usesCleartextTraffic") == "false"
    activities = {
        node.attrib.get(f"{{{ANDROID}}}name") for node in application.findall("activity")
    }
    assert "com.yalantis.ucrop.UCropActivity" in activities

    debug_manifest = Path("apps/mobile_flutter/android/app/src/debug/AndroidManifest.xml")
    debug_application = ET.parse(debug_manifest).getroot().find("application")
    assert debug_application is not None
    assert debug_application.attrib.get(f"{{{ANDROID}}}usesCleartextTraffic") == "true"
