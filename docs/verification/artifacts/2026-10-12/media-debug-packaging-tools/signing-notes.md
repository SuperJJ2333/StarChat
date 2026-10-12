# Fixed-identity signing wrapper restoration

Date: 2026-10-12 (Asia/Hong_Kong). Scope: restore packaging support only. No signing, ADB, installation, network operation or production change was performed by this restoration task.

## Original-file lookup

The exact historical path `docs/verification/artifacts/2026-09-05/background-call-signature/sign-diagnostic.ps1` does not exist in the primary StarChat tree or the `im-media-cache-review`, `im-reliability`, and `android2214-release` worktrees. The parent task had already searched the relevant verification trees and Git history for the other former wrapper names.

Only file names were listed in the documented `%USERPROFILE%/.chatflow-signing/diagnostic-20260905` directory: `diagnostic.p12` and `password.dpapi`. Neither file's content was read during restoration. The new wrapper follows [the repository packaging runbook](../../../../runbooks/android-apk-rebuild.md); it is a reconstruction, not a recovered historical original.

## Invocation and safety contract

The wrapper is [sign-existing-identity.ps1](sign-existing-identity.ps1). **The new `-Execute` switch is mandatory to sign. Omitting it returns `status=PLAN_ONLY`, `mode=plan`, `execute_required=true` and never produces an APK or decrypts the DPAPI file.** Do not treat a successful plan-only exit as a signed artifact.

Use already-defined, absolute `$AlignedApk` and `$FinalApk` paths in the current build's verification directory; the latter must not exist. The intended signing invocation is:

```powershell
$taskUtf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $taskUtf8
[Console]::OutputEncoding = $taskUtf8
$OutputEncoding = $taskUtf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
& 'C:/Users/Administrator/.codex/worktrees/im-media-cache-review/StarChat/docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/sign-existing-identity.ps1' -InputApk $AlignedApk -OutputApk $FinalApk -Apksigner 'C:/Users/Administrator/AppData/Local/Android/Sdk/build-tools/36.0.0/apksigner.bat' -Execute
```

Run with `pwsh.exe -NoProfile`; retain the exit code and non-sensitive JSON result. `Input`/`Output` are parameter aliases for `InputApk`/`OutputApk`. The caller must use the trusted SDK 36.0.0 tool and perform the other runbook gates, including alignment before signing, final zipalign, aapt/ABI, rebuild equivalence and assets checks. This wrapper is not the whole packaging gate.

The identity cannot be supplied or replaced via a wrapper argument:

- Keystore: `%USERPROFILE%/.chatflow-signing/diagnostic-20260905/diagnostic.p12`.
- DPAPI file: the same directory's `password.dpapi`.
- Alias: `chatflow-local-ab-20260905`.
- Certificate SHA-256: `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`, RSA 3072.

All input/tool/identity paths must be ordinary absolute local files. Missing files, empty input/identity files, an absent output directory, an existing output, equal input/output, alternate data streams, UNC paths, reparse-point ancestors and CMD expansion/metacharacters are rejected before password reading. Existing output is never overwritten.

On explicit execution, the wrapper decrypts the existing DPAPI value in memory, loads the P12 with ephemeral key storage, and checks the public certificate fingerprint and RSA size before calling the signing tool. It never generates a key. The password reaches apksigner only through a unique process environment variable referenced by `--ks-pass env:...` and `--key-pass env:...`; it is never a plaintext command argument, a new password file or displayed output. All apksigner stdout/stderr is captured and withheld, including unexpected failure output. Error messages contain only fixed stage labels.

A temporary APK in the destination directory must pass apksigner verification for exactly one expected RSA 3072 signer and v2/v3 signatures. The source hash must remain unchanged. Only then is the temporary APK moved to the final path with overwrite disabled. `finally` clears the task environment variable, releases the BSTR and SecureString, disposes imported certificates and the RSA public-key object, and removes a surviving temporary APK. Managed runtime strings cannot promise forensic zeroization; their references are cleared promptly and never deliberately persisted. Forced process termination is outside normal `finally` guarantees.

## Test evidence and limits

The tests are [test_sign_wrapper.py](test_sign_wrapper.py). They use disposable synthetic profiles below this verification directory, with deliberately invalid P12/DPAPI contents. No test accesses the real signing identity, invokes its password decryption or executes a real signing operation.

1. Initial RED: 14 tests failed for the intended absent-wrapper assertion, exit 1 (`3302ed`).
2. Initial implementation: 14 tests passed in 7.845 seconds, exit 0 (`c598db`).
3. Expanded cleanup test initially failed because PowerShell's property adapter did not expose disposal through `SecureString.Length`; the fixture was corrected to call `IsReadOnly()`, which throws after disposal. The wrapper was unchanged. All 17 tests passed in 10.067 seconds (`db7091` / `f66fd7`).
4. CMD path guard RED: four synthetic `%`, `!`, `&`, `^` input cases reached protected-identity loading instead of rejecting during path preflight, exit 1 (`1fe773`). The path validator was strengthened.
5. Final GREEN: **18 tests passed in 11.372 seconds**, exit 0 (`db76e5` / `0e8ef3`). No skips.

Coverage includes plan-only nonexecution, output preservation, equal paths, missing prerequisites, malformed DPAPI without content disclosure, junction ancestors, CMD metacharacters, accepted fixed-signer report, wrong/duplicate certificate, weak key, and missing v2/v3. PowerShell AST extraction executes the real argument expression against synthetic variables to prove environment references are passed, and executes the real `finally` block to check environment cleanup, SecureString disposal and temporary-file removal.

This is synthetic/static tool validation. Actual P12 import, alias resolution and final APK signing/verification remain dependent on the authorized caller's subsequent `-Execute` run. No actual signed artifact or device result is claimed here. The parent task performs specification review before security/quality review and records the combined packaging-tool evidence.
