"""No build/device/signing/network calls: synthetic closure boundaries only."""
from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch
HERE=Path(__file__).resolve().parent

def load():
    path=HERE/'verify_lock_closure.py'
    if not path.is_file():raise AssertionError('strict lock boundary closure not implemented')
    spec=importlib.util.spec_from_file_location('closure_test',path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

class ClosureBoundary(unittest.TestCase):
    def setUp(self):
        self.m=load();base=HERE/'test-scratch';base.mkdir(exist_ok=True)
        temp=tempfile.TemporaryDirectory(dir=base);self.addCleanup(temp.cleanup);self.root=Path(temp.name)
        self.names=['apps/mobile_flutter/android/AndroidManifest.xml','apps/mobile_flutter/pubspec.yaml','apps/mobile_flutter/pubspec.lock']
        values=[b'<manifest keep="true"/>',b'name: app\nversion: 0.4.46+2215\ndependencies: unchanged\n',b'  url: "https://pub.dev"\n']
        for name,value in zip(self.names,values):
            p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(value)
        self.baseline={'source_files':{n:self.m.sha(self.m.canonical_source(n,v,'0.4.46',2215)) for n,v in zip(self.names,values)},'reference_lock_sha256':self.m.sha(values[-1])}
    def verify(self):
        with patch.object(self.m,'source_names',return_value=self.names):return self.m.verify_source(self.root,self.baseline)
    def test_source_control_and_current_only_version_line(self):
        self.verify()
        pubspec=self.names[1]
        a=self.m.canonical_source(pubspec,b'version: 0.4.45+2214\r\n','0.4.45',2214)
        b=self.m.canonical_source(pubspec,b'version: 0.4.46+2215\n','0.4.46',2215)
        self.assertEqual(a,b)
        with self.assertRaises(ValueError):self.m.canonical_source(pubspec,b'version: 0.4.45+2214\n','0.4.46',2215)
    def test_native_dependency_or_extra_file_changes_rejected(self):
        for name in self.names:
            p=self.root/name;old=p.read_bytes();p.write_bytes(old+b'changed')
            with self.subTest(name=name),self.assertRaises(ValueError):self.verify()
            p.write_bytes(old)
        self.names.append('apps/mobile_flutter/android/Extra.kt')
        with self.assertRaises(ValueError):self.verify()
    def test_lockfile_host_and_exact_raw_bytes_preserved(self):
        p=self.root/self.names[-1];p.write_bytes(b'  url: "https://foreign.invalid"\n')
        with self.assertRaises(ValueError):self.verify()
    def test_decoded_control_changed_deleted_added_and_main_inner_class(self):
        decoded=self.root/'decoded';p=decoded/'smali_classes5/com/liuhetong/mobile/MainActivity.smali';p.parent.mkdir(parents=True);p.write_bytes(b'.class MainActivity\nunchanged\n')
        q=decoded/'smali_classes5/com/liuhetong/mobile/call/CallActivity.smali';q.parent.mkdir();q.write_bytes(b'.class CallActivity\nshowWhenLocked\n')
        expected=self.m.decoded_classes(decoded)
        self.m.require_equal_classes(decoded,expected)
        for target in (p,q):
            old=target.read_bytes();target.write_bytes(old+b'changed')
            with self.assertRaises(ValueError):self.m.require_equal_classes(decoded,expected)
            target.write_bytes(old)
        extra=p.with_name('MainActivity$extra.smali');extra.write_bytes(b'extra')
        with self.assertRaises(ValueError):self.m.require_equal_classes(decoded,expected)
        extra.unlink();q.unlink()
        with self.assertRaises(ValueError):self.m.require_equal_classes(decoded,expected)
    def test_duplicate_descriptor_across_dex_refused(self):
        for dex in ('smali','smali_classes10'):
            p=self.root/dex/'com/liuhetong/mobile/MainActivity.smali';p.parent.mkdir(parents=True);p.write_bytes(b'same')
        with self.assertRaises(ValueError):self.m.decoded_classes(self.root)
    def test_manifest_only_version_and_aapt_line_coordinates_normalize(self):
        before='  E: manifest (line=2)\n    A: android:versionCode(0x0101021b)=(type 0x10)0x8a6\n    A: android:versionName(0x0101021c)="0.4.45" (Raw: "0.4.45")\n    A: android:showWhenLocked=false\n'
        after=before.replace('line=2','line=20').replace('0x8a6','0x8a7').replace('0.4.45','0.4.46')
        self.assertEqual(self.m.normalize_manifest(before,'0.4.45',2214),self.m.normalize_manifest(after,'0.4.46',2215))
        self.assertNotEqual(self.m.normalize_manifest(before,'0.4.45',2214),self.m.normalize_manifest(after.replace('false','true'),'0.4.46',2215))
        with self.assertRaises(ValueError):self.m.normalize_manifest(before,'0.4.46',2215)
        with self.assertRaises(ValueError):self.m.normalize_manifest(after+after,'0.4.46',2215)

    def test_binary_source_and_manifest_literal_are_not_normalized(self):
        self.assertNotEqual(self.m.canonical_source('apps/mobile_flutter/android/icon.png',b'\x89PNG\r\n','0.4.46',2215),self.m.canonical_source('apps/mobile_flutter/android/icon.png',b'\x89PNG\n','0.4.46',2215))
        text='  E: manifest (line=2)\n    A: android:versionCode(0x0101021b)=(type 0x10)0x8a7\n    A: android:versionName(0x0101021c)="0.4.46" (Raw: "0.4.46")\n    A: label="(line=2)"\n'
        self.assertNotEqual(self.m.normalize_manifest(text,'0.4.46',2215),self.m.normalize_manifest(text.replace('label="(line=2)"','label="(line=20)"'),'0.4.46',2215))

if __name__=='__main__':unittest.main()
