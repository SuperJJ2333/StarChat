# DPAPI file line-terminator regression

Date: 2026-10-12. This follow-up adds one isolated regression after the release owner observed that reading an existing DPAPI text file with `Get-Content -Raw` retained its terminal newline and caused `ConvertTo-SecureString` to throw `System.FormatException`.

Only [test_sign_wrapper.py](test_sign_wrapper.py) was changed, plus the evidence files linked below. Neither this task's original wrapper nor the release owner's corrected wrapper was modified. No real P12, real DPAPI file, signing command, ADB command or remote operation was accessed or executed by this follow-up.

The test creates its own temporary `USERPROFILE` beneath the verification fixtures. Under that profile it uses the current Windows user's actual DPAPI implementation to serialize a known synthetic SecureString, then appends CRLF to the encoded text. It parses the candidate script and executes only its actual `$taskSecurePassword` read/decrypt assignment. The whole signing wrapper is not executed by this new case. It compares the result in memory and emits only a boolean and, on failure, an exception type. The synthetic plaintext includes deliberate surrounding spaces, so the test also proves that trimming serialized text does not trim the password value itself. The BSTR, SecureStrings and temporary fixture are cleaned up; no decrypted value is printed.

## RED and GREEN

- [RED log](dpapi-format-red.log), [RED receipt](dpapi-format-red-receipt.json): the unchanged adjacent wrapper, SHA-256 `1baf91b7c2e3ed7951c3c3f9fab623d9cf6355d3dc3a2eade29f58508183b7d0`, failed the new case with `System.FormatException`. Exit 1; one intended test failure. UTC 12:04:48.2213039–12:04:48.9968910. Test-runner duration 0.605 seconds; process wall time 0.7738658 seconds.
- [GREEN log](dpapi-format-green.log), [GREEN receipt](dpapi-format-green-receipt.json): the release owner's candidate, SHA-256 `eef1c12edf36c800166447911e6cc08f56ebb53224d7b24a40670ea07d1413a4`, passed **all 19 synthetic tests**, no skips. Exit 0. UTC 12:05:08.9665512–12:05:20.8017174. Test-runner duration 11.693 seconds; process wall time 11.8340517 seconds. Candidate hash remained identical before and after the run.

The candidate's only wrapper change is `(Get-Content -LiteralPath $taskDpapi -Raw -Encoding utf8).Trim() | ConvertTo-SecureString`. It retains the fixed identity, environment password channel, output-preservation checks, verification and cleanup behavior covered by the original 18 cases.

Both runs used test source SHA-256 `7cb68309598f3e92c215600e0c5efbe161d001b095485ab3f84c7506267d3f3d`. The RED log SHA-256 is `0ddd4aad9e5aaba21b9548144d149c9c31895bc3fdc1faba1aa319e4fea1f43d`; the GREEN log SHA-256 is `8c4e10fb6693578f9ef1750cc03d3d86cf21ed39966074678d652222a2f5c7c1`.

## Integration and reproduction

The test defaults to the adjacent wrapper. **The old adjacent wrapper remains intentionally RED until the release owner's separate one-line fix is integrated.** This test-only environment selector permits reviewing another candidate without modifying either wrapper:

```powershell
$taskUtf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $taskUtf8
[Console]::OutputEncoding = $taskUtf8
$OutputEncoding = $taskUtf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:CHATFLOW_SIGN_WRAPPER_UNDER_TEST = 'C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/sign-existing-identity.ps1'
try {
    py -3.12 'C:/Users/Administrator/.codex/worktrees/im-media-cache-review/StarChat/docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/test_sign_wrapper.py'
} finally {
    Remove-Item Env:CHATFLOW_SIGN_WRAPPER_UNDER_TEST -ErrorAction SilentlyContinue
}
```

Use PowerShell 7. This evidence proves the isolated format correction and the 19 synthetic boundaries; the release owner's actual identity preflight and APK signing evidence are separate. The parent reviewer owns final specification/security review, metadata consolidation and commit.
