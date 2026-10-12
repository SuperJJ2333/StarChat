"""Isolated signing-wrapper gates; never read or invoke the real signing identity."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
WRAPPER = HERE / 'sign-existing-identity.ps1'
CERT = '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'
PWSH = shutil.which('pwsh.exe')


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(WRAPPER.is_file(), 'Restored signing wrapper is missing')
        self.assertIsNotNone(PWSH, 'PowerShell 7 is required')
        self.artifacts = HERE / 'signing-test-artifacts'
        self.artifacts.mkdir(exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='synthetic-', dir=self.artifacts))
        self.addCleanup(self.remove_fixture)
        self.profile = self.tmp / 'profile'
        self.identity = self.profile / '.chatflow-signing' / 'diagnostic-20260905'
        self.identity.mkdir(parents=True)
        (self.identity / 'diagnostic.p12').write_text('synthetic-not-a-p12', encoding='utf-8')
        (self.identity / 'password.dpapi').write_text('synthetic-not-dpapi', encoding='utf-8')
        self.input = self.tmp / 'aligned.apk'
        self.input.write_bytes(b'synthetic APK input')
        self.output = self.tmp / 'final.apk'
        self.signer = self.tmp / 'apksigner.ps1'
        self.marker = self.tmp / 'unexpected-signer-invocation'
        self.signer.write_text("[IO.File]::WriteAllText($env:SIGN_TEST_MARKER, 'called'); throw 'SYNTHETIC_SECRET_DO_NOT_PRINT'", encoding='utf-8')
        self.env = os.environ.copy()
        self.env.update(USERPROFILE=str(self.profile), SIGN_TEST_MARKER=str(self.marker), PYTHONUTF8='1', PYTHONIOENCODING='utf-8')

    def remove_fixture(self):
        target = self.tmp.resolve()
        self.assertTrue(target.is_relative_to(self.artifacts.resolve()))
        shutil.rmtree(target)

    def run_wrapper(self, execute=False):
        args = [PWSH, '-NoProfile', '-File', str(WRAPPER), '-InputApk', str(self.input), '-OutputApk', str(self.output), '-Apksigner', str(self.signer)]
        if execute:
            args.append('-Execute')
        return subprocess.run(args, env=self.env, capture_output=True, text=True, encoding='utf-8', timeout=20)

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.marker.exists(), 'An invalid request invoked the signer')
        self.assertNotIn('SYNTHETIC_SECRET_DO_NOT_PRINT', result.stdout + result.stderr)

    def test_default_is_plan_only_and_never_decrypts_synthetic_password(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['status'], 'PLAN_ONLY')
        self.assertEqual(data['mode'], 'plan')
        self.assertIs(data['execute_required'], True)
        self.assertEqual(data['certificate_sha256'], CERT)
        self.assertEqual(data['alias'], 'chatflow-local-ab-20260905')
        self.assertFalse(self.output.exists())
        self.assertFalse(self.marker.exists())

    def test_existing_output_is_preserved(self):
        self.output.write_bytes(b'keep original output')
        self.assert_rejected(self.run_wrapper(True))
        self.assertEqual(self.output.read_bytes(), b'keep original output')

    def test_same_input_output_is_rejected(self):
        self.output = self.input
        self.assert_rejected(self.run_wrapper(True))
        self.assertEqual(self.input.read_bytes(), b'synthetic APK input')

    def test_missing_input_is_rejected(self):
        self.input.unlink()
        self.assert_rejected(self.run_wrapper(True))

    def test_missing_signer_is_rejected(self):
        self.signer.unlink()
        self.assert_rejected(self.run_wrapper(True))

    def test_missing_keystore_is_rejected(self):
        (self.identity / 'diagnostic.p12').unlink()
        self.assert_rejected(self.run_wrapper(True))

    def test_missing_dpapi_is_rejected(self):
        (self.identity / 'password.dpapi').unlink()
        self.assert_rejected(self.run_wrapper(True))

    def test_malformed_dpapi_fails_without_disclosing_contents_or_creating_output(self):
        (self.identity / 'password.dpapi').write_text('SYNTHETIC_SECRET_DO_NOT_PRINT', encoding='utf-8')
        self.assert_rejected(self.run_wrapper(True))
        self.assertFalse(self.output.exists())

    def test_missing_output_directory_is_not_created(self):
        self.output = self.tmp / 'absent' / 'final.apk'
        self.assert_rejected(self.run_wrapper(True))
        self.assertFalse(self.output.parent.exists())

    def test_cmd_metacharacters_are_rejected_before_password_read(self):
        for name in ('percent%TEMP%.apk', 'bang!name.apk', 'amp&name.apk', 'caret^name.apk'):
            with self.subTest(name=name):
                self.input = self.tmp / name
                self.input.write_bytes(b'synthetic APK input')
                result = self.run_wrapper(True)
                self.assert_rejected(result)
                self.assertIn('path preflight', result.stderr)

    def run_ast_harness(self, body):
        harness = self.tmp / 'ast-harness.ps1'
        harness.write_text('''param([string]$Source,[string]$Fixture)
$ErrorActionPreference='Stop'
$taskUtf8=[Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8; [Console]::OutputEncoding=$taskUtf8; $OutputEncoding=$taskUtf8
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Invalid wrapper syntax'}
''' + body, encoding='utf-8')
        return subprocess.run([PWSH, '-NoProfile', '-File', str(harness), '-Source', str(WRAPPER), '-Fixture', str(self.tmp)], env=self.env, capture_output=True, text=True, encoding='utf-8', timeout=20)

    def test_linked_input_ancestor_is_rejected_before_password_read(self):
        target = self.tmp / 'real'
        target.mkdir()
        (target / 'aligned.apk').write_bytes(b'fixture')
        linked = self.tmp / 'linked'
        env = self.env | {'SIGN_TEST_LINK': str(linked), 'SIGN_TEST_TARGET': str(target)}
        result = subprocess.run([PWSH, '-NoProfile', '-Command', "$ErrorActionPreference='Stop'; $taskUtf8=[System.Text.UTF8Encoding]::new($false); [Console]::InputEncoding=$taskUtf8; [Console]::OutputEncoding=$taskUtf8; $OutputEncoding=$taskUtf8; New-Item -ItemType Junction -Path $env:SIGN_TEST_LINK -Target $env:SIGN_TEST_TARGET | Out-Null"], env=env, capture_output=True, text=True, encoding='utf-8', timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.input = linked / 'aligned.apk'
        self.assert_rejected(self.run_wrapper(True))

    def test_real_argument_expression_passes_only_environment_reference(self):
        result = self.run_ast_harness('''
$assignment=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$taskSignArguments'},$true)
if($null -eq $assignment){throw 'Missing signing arguments'}
$taskKeystore='synthetic.p12'; $taskAlias='chatflow-local-ab-20260905'
$taskPassword='SYNTHETIC_SECRET_DO_NOT_PRINT'; $taskPasswordEnvironmentName='SYNTHETIC_SIGN_PASSWORD'
$taskInput='aligned.apk'; $taskTemporaryApk='temporary.apk'
$actual=& ([scriptblock]::Create($assignment.Right.Extent.Text))
ConvertTo-Json -InputObject @($actual) -Compress
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout)
        for flag in ('--ks-pass', '--key-pass'):
            self.assertEqual(args[args.index(flag) + 1], 'env:SYNTHETIC_SIGN_PASSWORD')
        self.assertNotIn('SYNTHETIC_SECRET_DO_NOT_PRINT', result.stdout + result.stderr)
        self.assertEqual(args[args.index('--ks-key-alias') + 1], 'chatflow-local-ab-20260905')

    def test_real_finally_clears_environment_and_temporary_output(self):
        result = self.run_ast_harness('''
$tryStatement=$ast.Find({param($n) $n -is [Management.Automation.Language.TryStatementAst]},$true)
if($null -eq $tryStatement.Finally){throw 'Missing finally cleanup'}
$taskPasswordEnvironmentName='SYNTHETIC_SIGN_CLEANUP_'+[Guid]::NewGuid().ToString('N')
[Environment]::SetEnvironmentVariable($taskPasswordEnvironmentName,'SYNTHETIC_SECRET_DO_NOT_PRINT','Process')
$taskPassword='SYNTHETIC_SECRET_DO_NOT_PRINT'; $taskToolOutput=$taskPassword
$taskSecurePassword=ConvertTo-SecureString 'synthetic' -AsPlainText -Force
$taskPasswordPointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($taskSecurePassword)
$taskPublicKey=$null; $taskCertificates=$null
$taskTemporaryApk=Join-Path $Fixture 'synthetic-temporary.apk'
[IO.File]::WriteAllText($taskTemporaryApk,'temporary')
. ([scriptblock]::Create($tryStatement.Finally.Extent.Text.Trim().TrimStart('{').TrimEnd('}')))
if([Environment]::GetEnvironmentVariable($taskPasswordEnvironmentName,'Process')){throw 'Environment was not cleared'}
if(Test-Path -LiteralPath $taskTemporaryApk){throw 'Temporary file survived cleanup'}
if($null -ne $taskPassword -or $null -ne $taskToolOutput){throw 'Sensitive references survived cleanup'}
$disposed=$false
try{$null=$taskSecurePassword.IsReadOnly()}catch{$disposed=$true}
if(-not $disposed){throw 'SecureString was not disposed'}
'CLEANED'
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CLEANED', result.stdout)
        self.assertEqual(self.input.read_bytes(), b'synthetic APK input')

    def run_verifier(self, lines):
        # Parse only the actual verification function; never dot-source the main script.
        harness = self.tmp / 'verify-harness.ps1'
        payload = self.tmp / 'verification.json'
        payload.write_text(json.dumps(lines), encoding='utf-8')
        harness.write_text('''param([string]$Source,[string]$Payload)
$ErrorActionPreference='Stop'
$taskUtf8=[Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$taskUtf8; [Console]::OutputEncoding=$taskUtf8; $OutputEncoding=$taskUtf8
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Invalid wrapper syntax'}
$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ApkVerification'},$true)
if($null -eq $function){throw 'Missing verification function'}
. ([scriptblock]::Create($function.Extent.Text))
$lines=Get-Content -LiteralPath $Payload -Raw -Encoding utf8 | ConvertFrom-Json
Assert-ApkVerification -Lines $lines
'VERIFIED'
''', encoding='utf-8')
        return subprocess.run([PWSH, '-NoProfile', '-File', str(harness), '-Source', str(WRAPPER), '-Payload', str(payload)], env=self.env, capture_output=True, text=True, encoding='utf-8', timeout=20)

    def valid_report(self):
        return ['Verifies', 'Verified using v2 scheme (APK Signature Scheme v2): true', 'Verified using v3 scheme (APK Signature Scheme v3): true', 'Number of signers: 1', f'Signer #1 certificate SHA-256 digest: {CERT}', 'Signer #1 key algorithm: RSA', 'Signer #1 key size (bits): 3072']

    def test_verified_fixed_identity_is_accepted(self):
        result = self.run_verifier(self.valid_report())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('VERIFIED', result.stdout)

    def test_wrong_certificate_is_rejected(self):
        result = self.run_verifier([line.replace(CERT, '0' * 64) for line in self.valid_report()])
        self.assertNotEqual(result.returncode, 0)

    def test_duplicate_signer_report_is_rejected(self):
        result = self.run_verifier(self.valid_report() + [f'Signer #2 certificate SHA-256 digest: {CERT}'])
        self.assertNotEqual(result.returncode, 0)

    def test_weak_key_is_rejected(self):
        result = self.run_verifier([line.replace('3072', '2048') for line in self.valid_report()])
        self.assertNotEqual(result.returncode, 0)

    def test_missing_v2_or_v3_is_rejected(self):
        for scheme in ('v2', 'v3'):
            with self.subTest(scheme=scheme):
                result = self.run_verifier([line.replace(': true', ': false') if f'using {scheme} ' in line else line for line in self.valid_report()])
                self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
