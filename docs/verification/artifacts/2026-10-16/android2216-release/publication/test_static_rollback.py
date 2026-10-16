"""Reviewer regressions: synthetic local static files; no production writes."""
from contextlib import nullcontext
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


class StaticRollback(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('rollback_review_release', HERE/'payload/release_2216.py')
        self.release = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.release)
        scratch=HERE/'test-scratch'; scratch.mkdir(exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=scratch); self.addCleanup(self.temp.cleanup)
        base=Path(self.temp.name)
        self.root,self.stage,self.backup=(base/n for n in ('root','stage','backup'))
        self.root.mkdir(); self.stage.mkdir()
        for name in ('page','registry'):
            (self.root/name).write_bytes(b'old-'+name.encode())
            (self.stage/name).write_bytes(b'new-'+name.encode())
        (self.root/'ios').write_bytes(b'unchanged-ios')
        self.plan={'static':{name:{'before':self.release.sha((self.root/name).read_bytes()),
                                  'after':self.release.sha((self.stage/name).read_bytes())}
                             for name in ('page','registry')},
                   'preserved':{'ios':self.release.sha(b'unchanged-ios')}}

    def test_failed_second_write_never_restores_corrupted_backup(self):
        atomic=self.release.atomic
        def fault(path,data):
            if path.name=='registry' and data==b'new-registry':
                (self.backup/'page').write_bytes(b'CORRUPTED_BACKUP')
                raise OSError('second static write failed')
            atomic(path,data)
        with patch.object(self.release,'atomic',fault), self.assertRaises(OSError):
            self.release.apply_static(self.plan,self.root,self.stage,self.backup,lock=lambda _:nullcontext())
        self.assertEqual((self.root/'page').read_bytes(),b'old-page')
        self.assertEqual((self.root/'registry').read_bytes(),b'old-registry')
        self.assertEqual((self.root/'ios').read_bytes(),b'unchanged-ios')

    def test_failed_second_write_preserves_foreign_target(self):
        atomic=self.release.atomic
        def fault(path,data):
            if path.name=='registry' and data==b'new-registry':
                (self.root/'page').write_bytes(b'FOREIGN_NEWER_PAGE')
                raise OSError('second static write failed')
            atomic(path,data)
        with patch.object(self.release,'atomic',fault), self.assertRaises(OSError):
            self.release.apply_static(self.plan,self.root,self.stage,self.backup,lock=lambda _:nullcontext())
        self.assertEqual((self.root/'page').read_bytes(),b'FOREIGN_NEWER_PAGE')
        self.assertEqual((self.root/'ios').read_bytes(),b'unchanged-ios')

    def test_both_captured_snapshot_copies_preserve_original_live_bytes(self):
        for folder in ('baseline','payload'):
            for name,identity in self.release.FROZEN_STATIC.items():
                path=HERE/folder/'hk-snapshot'/name
                with self.subTest(folder=folder,name=name):
                    self.assertEqual(path.stat().st_size,identity['bytes'])
                    self.assertEqual(self.release.digest(path),identity['sha256'])


if __name__=='__main__': unittest.main()
