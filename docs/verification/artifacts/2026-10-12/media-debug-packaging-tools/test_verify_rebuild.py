"""Synthetic rebuild-verifier contract; fixtures contain no app/user data."""
from pathlib import Path
import importlib.util, json, subprocess, sys, tempfile, unittest, zipfile, warnings
HERE=Path(__file__).resolve().parent
TOOL=HERE/'verify_rebuild.py'
SMALI='''.class public Lexample/Test;
.super Ljava/lang/Object;
.field public static enabled:Z = false
.field public static number:I = 0x0
.field public static reference:Ljava/lang/String; = null
.method public static result()I
    .locals 1
    const/4 v0, 0x1
    return v0
.end method
'''
MANIFEST='''N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=2)
    A: package="example.app" (Raw: "example.app")
    E: application (line=8)
      A: android:debuggable(0x0101000f)=(type 0x12)0xffffffff
'''

class Contract(unittest.TestCase):
 def test_tool_is_restored(self):self.assertTrue(TOOL.is_file(),'required archived verifier is absent and must be restored')

class SemanticTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  spec=importlib.util.spec_from_file_location('restored_rebuild',TOOL);cls.mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.mod)
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(dir=HERE,prefix='synthetic-');self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  for directory in ('decoded','verified-decoded'):
   p=self.root/directory/'smali/example/Test.smali';p.parent.mkdir(parents=True);p.write_text(SMALI,encoding='utf-8')
  for name in ('original-manifest.txt','rebuilt-manifest.txt'):(self.root/name).write_text(MANIFEST,encoding='utf-8')
  self.entries={'classes.dex':b'dex-source','resources.arsc':b'resources','AndroidManifest.xml':b'binary-manifest','assets/test.bin':b'asset','lib/x86_64/libexample.so':b'elf','res/raw/test.txt':b'resource'}
  self.writezip('source.apk',self.entries);self.writezip('final.apk',dict(self.entries,**{'classes.dex':b'dex-rebuilt'}))
 def writezip(self,name,entries):
  with zipfile.ZipFile(self.root/name,'w') as z:
   for n,b in entries.items():z.writestr(n,b)
 def finalsmali(self,text):(self.root/'verified-decoded/smali/example/Test.smali').write_text(text,encoding='utf-8')
 def rejected(self):
  with self.assertRaises(self.mod.VerificationError):self.mod.verify(self.root)
 def test_valid_rebuild_and_only_default_static_omission(self):
  self.finalsmali(SMALI.replace(' = false','').replace(' = 0x0','').replace(' = null',''))
  (self.root/'rebuilt-manifest.txt').write_text(MANIFEST.replace('(line=8)','(line=99)'),encoding='utf-8')
  r=self.mod.verify(self.root);self.assertEqual(r['source_class_count'],1);self.assertEqual(r['method_count'],1);self.assertEqual(r['native_asset_entries'],2);self.assertTrue(r['manifest_semantics_identical'])
 def test_package_private_class_is_compared(self):
  for directory in ('decoded','verified-decoded'):(self.root/directory/'smali/example/Test.smali').write_text(SMALI.replace('.class public ','.class '),encoding='utf-8')
  self.assertEqual(self.mod.verify(self.root)['source_class_count'],1)
 def test_method_instruction_change_rejected(self):self.finalsmali(SMALI.replace('const/4 v0, 0x1','const/4 v0, 0x0'));self.rejected()
 def test_method_annotation_change_rejected(self):self.finalsmali(SMALI.replace('    .locals 1','    .annotation runtime Lexample/Changed;\n    .end annotation\n    .locals 1'));self.rejected()
 def test_removed_method_rejected(self):self.finalsmali(SMALI[:SMALI.index('.method')]);self.rejected()
 def test_instance_default_must_not_be_normalized(self):
  source=SMALI.replace('.field public static enabled:Z','.field public enabled:Z');(self.root/'decoded/smali/example/Test.smali').write_text(source,encoding='utf-8');self.finalsmali(source.replace(' = false',''));self.rejected()
 def test_nonzero_static_rejected(self):self.finalsmali(SMALI.replace('number:I = 0x0','number:I = 0x1'));self.rejected()
 def test_boolean_numeric_zero_not_normalized(self):self.finalsmali(SMALI.replace('enabled:Z = false','enabled:Z = 0x0'));self.rejected()
 def test_float_zero_not_normalized(self):
  source=SMALI.replace('number:I = 0x0','number:F = 0.0f');(self.root/'decoded/smali/example/Test.smali').write_text(source,encoding='utf-8');self.finalsmali(source.replace(' = 0.0f',''));self.rejected()
 def test_reference_integer_zero_not_normalized(self):self.finalsmali(SMALI.replace('reference:Ljava/lang/String; = null','reference:Ljava/lang/String; = 0x0'));self.rejected()
 def test_instance_annotation_change_rejected(self):self.finalsmali(SMALI+'\n.annotation runtime Lexample/Changed;\n.end annotation\n');self.rejected()
 def test_added_class_rejected(self):(self.root/'verified-decoded/smali/example/Extra.smali').write_text(SMALI.replace('Lexample/Test;','Lexample/Extra;'),encoding='utf-8');self.rejected()
 def test_duplicate_class_descriptor_rejected(self):
  for directory in ('decoded','verified-decoded'):(self.root/directory/'smali/example/Duplicate.smali').write_text(SMALI,encoding='utf-8')
  self.rejected()
 def test_empty_smali_rejected(self):
  for directory in ('decoded','verified-decoded'):(self.root/directory/'smali/example/Test.smali').unlink()
  self.rejected()
 def test_manifest_permission_or_flag_change_rejected(self):(self.root/'rebuilt-manifest.txt').write_text(MANIFEST.replace('0xffffffff','0x0'),encoding='utf-8');self.rejected()
 def test_manifest_indent_structure_change_rejected(self):(self.root/'rebuilt-manifest.txt').write_text(MANIFEST.replace('    E: application','  E: application'),encoding='utf-8');self.rejected()
 def test_manifest_empty_rejected(self):
  for n in ('original-manifest.txt','rebuilt-manifest.txt'):(self.root/n).write_text('',encoding='utf-8')
  self.rejected()
 def test_manifest_unrecognized_output_rejected(self):
  for n in ('original-manifest.txt','rebuilt-manifest.txt'):(self.root/n).write_text('error: missing manifest',encoding='utf-8')
  self.rejected()
 def test_asset_changed_rejected(self):self.writezip('final.apk',dict(self.entries,**{'assets/test.bin':b'changed'}));self.rejected()
 def test_native_removed_rejected(self):self.writezip('final.apk',{k:v for k,v in self.entries.items() if not k.startswith('lib/')});self.rejected()
 def test_asset_added_rejected(self):self.writezip('final.apk',dict(self.entries,**{'assets/extra.bin':b'new'}));self.rejected()
 def test_dex_added_rejected(self):self.writezip('final.apk',dict(self.entries,**{'classes2.dex':b'new'}));self.rejected()
 def test_duplicate_zip_entry_rejected(self):
  with warnings.catch_warnings():
   warnings.simplefilter('ignore');
   with zipfile.ZipFile(self.root/'final.apk','a') as z:z.writestr('classes.dex',b'duplicate')
  self.rejected()
 def test_empty_resources_rejected(self):self.writezip('final.apk',dict(self.entries,**{'resources.arsc':b''}));self.rejected()
 def test_tenth_dex_added_rejected(self):self.writezip('final.apk',dict(self.entries,**{'classes10.dex':b'new'}));self.rejected()
 def test_tenth_smali_folder_instruction_change_rejected(self):
  for directory in ('decoded','verified-decoded'):
   p=self.root/directory/'smali_classes10/example/Tenth.smali';p.parent.mkdir(parents=True);p.write_text(SMALI.replace('Lexample/Test;','Lexample/Tenth;'),encoding='utf-8')
  p=self.root/'verified-decoded/smali_classes10/example/Tenth.smali';p.write_text(p.read_text().replace('const/4 v0, 0x1','const/4 v0, 0x0'),encoding='utf-8');self.rejected()
 def test_cli_nonzero_on_drift(self):
  self.finalsmali(SMALI.replace('return v0','return v1'));r=subprocess.run([sys.executable,str(TOOL),str(self.root)],capture_output=True,text=True);self.assertNotEqual(r.returncode,0);self.assertEqual(json.loads(r.stdout)['status'],'fail')

if __name__=='__main__':unittest.main(verbosity=2)
