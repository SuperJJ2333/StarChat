from pathlib import Path
import xml.etree.ElementTree as ET


def test_launcher_reuses_one_application_task():
    root = ET.parse(Path(__file__).resolve().parents[2] /
                    'apps/mobile_flutter/android/app/src/main/AndroidManifest.xml').getroot()
    ns = '{http://schemas.android.com/apk/res/android}'
    main = next(a for a in root.findall('./application/activity')
                if a.get(ns + 'name') == '.MainActivity')
    assert main.get(ns + 'launchMode') == 'singleTask'
    assert main.get(ns + 'taskAffinity') != ''
    assert main.get(ns + 'documentLaunchMode') == 'never'
