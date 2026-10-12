"""Execute only the real preflight prefix; an unconditional throw replaces the build tail."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
HERE=Path(__file__).resolve().parent

class CandidatePreflight(unittest.TestCase):
    def setUp(self):
        base=HERE/'test-scratch';base.mkdir(exist_ok=True);temp=tempfile.TemporaryDirectory(dir=base);self.addCleanup(temp.cleanup);self.root=Path(temp.name)
        self.candidate=self.root/'candidate';self.candidate.mkdir();self.repo=self.root/'repo';self.repo.mkdir()
        identities=json.loads((HERE/'candidate-tool-identities.json').read_text(encoding='utf-8'))
        for name in [*identities['files'],'candidate-tool-identities.json']:
            target=self.candidate/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(HERE/name,target)
        text=(HERE/'build-android-2215-arm64.ps1').read_text(encoding='utf-8')
        marker='$sourceMappingOwned = $false\n'
        assert text.count(marker)==1
        self.driver=self.candidate/'build.ps1';self.driver.write_text(text.split(marker)[0]+"throw 'TEST_BUILD_BOUNDARY_REACHED_NO_BUILD_EXECUTED'\n",encoding='utf-8')
        files={'.git':'synthetic identity only','apps/mobile_flutter/pubspec.yaml':'version: 0.4.46+2215\n','apps/mobile_flutter/lib/core/app_config.dart':"const appVersionName = '0.4.46'; const compiledBuildNumber = 2215;",'apps/mobile_flutter/pubspec.lock':'synthetic lock','apps/mobile_flutter/.dart_tool/package_config.json':'{}','apps/mobile_flutter/.flutter-plugins-dependencies':'{}','scripts/verify_android_release.py':'# synthetic','scripts/bump_version.ps1':'# compiledBuildNumber','tests/mobile/test_app_build_contract.py':'# compiledBuildNumber'}
        for name,value in files.items():
            p=self.repo/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(value,encoding='utf-8')
        self.profile=self.root/'profile';signing=self.profile/'.chatflow-signing/diagnostic-20260905';signing.mkdir(parents=True)
        for name in ('diagnostic.p12','password.dpapi'):(signing/name).write_bytes(b'SYNTHETIC-NOT-A-KEY-NOT-A-SECRET')
        self.manifest=self.root/'mobile-inputs.json';self.manifest.write_bytes(b'{}\n');self.sha=hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.wrapper=self.root/'harness.ps1';self.wrapper.write_text(r'''param($Driver,$Repo,$Manifest,$ManifestSha,$Profile,$Mode)
$ErrorActionPreference='Stop'
$e=[System.Text.UTF8Encoding]::new($false);[Console]::InputEncoding=$e;[Console]::OutputEncoding=$e;$OutputEncoding=$e
$env:PYTHONUTF8='1';$env:PYTHONIOENCODING='utf-8';$env:PYTHONDONTWRITEBYTECODE='1';$env:USERPROFILE=$Profile;$env:KEYSTORE_FILE=$null
$global:TaskMockCalls=@()
function global:py {
 $global:TaskMockCalls+=,@($args)
 if($args -contains '--expected-baseline-sha256') {
  if($Mode -eq 'closure-fail'){$global:LASTEXITCODE=1;return}
  $global:LASTEXITCODE=0;return '{"status":"SOURCE_LOCK_CLOSURE_EXACT"}'
 }
 $global:LASTEXITCODE=0
 return (@{version='0.4.46';build=2215;source_commit=('b'*40);manifest_sha256=$ManifestSha;file_count=1}|ConvertTo-Json -Compress)
}
function global:New-Item {throw 'TEST_FORBIDDEN_PREFLIGHT_WRITE'}
function global:subst.exe {throw 'TEST_FORBIDDEN_MAPPING'}
$extra=@{};if($Mode-eq 'execute'){$extra.Execute=$true}
$result=@(& $Driver -Worktree $Repo -MobileManifest $Manifest -ExpectedMobileManifestSha256 $ManifestSha -ConfirmedProductionAndroidBuild 2214 -ConfirmedProductionIosBuild 2213 -ProductionCheckedAtUtc ([DateTimeOffset]::UtcNow) -RunId run-20261012-000000-test @extra)
@{result=(($result -join "`n")|ConvertFrom-Json);mocked_readonly_python_calls=$global:TaskMockCalls.Count}|ConvertTo-Json -Depth 5
''',encoding='utf-8')
    def run_driver(self,mode='plan'):
        return subprocess.run(['pwsh.exe','-NoProfile','-File',str(self.wrapper),str(self.driver),str(self.repo),str(self.manifest),self.sha,str(self.profile),mode],capture_output=True,text=True,encoding='utf-8',timeout=20)
    def test_default_prefix_returns_preflight_without_writes_or_build_tail(self):
        p=self.run_driver();self.assertEqual(p.returncode,0,p.stderr);value=json.loads(p.stdout)
        self.assertFalse(value['result']['build_started']);self.assertTrue(value['result']['execute_required']);self.assertEqual(value['mocked_readonly_python_calls'],2)
        self.assertFalse((self.repo/'apps/mobile_flutter/build').exists());self.assertFalse((self.candidate/'run-20261012-000000-test').exists())
    def test_explicit_execute_is_required_to_reach_guarded_off_test_tail(self):
        p=self.run_driver('execute');self.assertNotEqual(p.returncode,0);self.assertIn('TEST_BUILD_BOUNDARY_REACHED_NO_BUILD_EXECUTED',p.stderr)
    def test_old_source_version_refused_in_preflight(self):
        (self.repo/'apps/mobile_flutter/pubspec.yaml').write_text('version: 0.4.45+2214\n',encoding='utf-8')
        p=self.run_driver();self.assertNotEqual(p.returncode,0);self.assertIn('must both be 0.4.46+2215',p.stderr)
    def test_tool_drift_and_closure_failure_refused(self):
        p=self.run_driver('closure-fail');self.assertNotEqual(p.returncode,0);self.assertIn('source closure changed',p.stderr)
        (self.candidate/'tools/sign-existing-identity.ps1').write_text('# changed',encoding='utf-8')
        p=self.run_driver();self.assertNotEqual(p.returncode,0);self.assertIn('helper identity drift',p.stderr)

if __name__=='__main__':unittest.main()
