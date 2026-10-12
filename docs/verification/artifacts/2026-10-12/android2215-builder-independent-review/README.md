# Android2215 builder independent review

**Preparation-only PASS:** `45341ce97e60e7ceee55675f725e1dec0357b36a`. Review order: [SPEC/domain](01-spec-domain.md), then [QUALITY/security](02-quality-security.md). [Machine-readable scope and evidence](preparation-review.json).

The original e987 candidate was [rejected](e987-rejection.md) because its copied signer omitted the proven DPAPI serialized-text `.Trim()` fix. Independent reproduction remains RED; the corrected copied file is exactly `eef1c12e...` from `3edbf003...`, and the identical synthetic regression now passes.

| Independent evidence | Result | Scope |
|---|---|---|
| e987 exact export and guarded tests | 28 blobs; 27 manifest / 8 tools; 11 PASS, 2.824 s | Seven closure and four synthetic preflight tests; no actual build tail |
| e987 copied-signer regression | 1 intended FAIL, 0.702 s | Synthetic real Windows DPAPI, `System.FormatException` |
| Historical reference closure | 400 Git source files, original APK/receipt/steps, 57 decoded classes and full manifest agree | Read-only actual old objects, no repeat decode |
| Corrected candidate identities | 35 blobs; 34 manifest / 8 tools | Only existing helper change is serialized `.Trim()`; 12 listed inputs unchanged |
| Corrected guarded preflight | 4 PASS, 3.666 s | Exact candidate export; actual tail replaced before invocation |
| Corrected same DPAPI regression | 1 PASS, 0.746 s | Preserves decrypted password whitespace, no signer invocation |

Source and artifact identity evidence is recorded in the two input-identity JSONs and `independent-reference-closure.json`. Raw logs and timing receipts are adjacent. Times in the table are the unittest-reported durations; process elapsed values are separately named in receipts. Initial independent execution began at 2026-10-12T12:50:11Z, historical closure was recorded at 12:51:27Z, and corrected incremental tests ran 13:04:38–13:04:43Z. Report writing is not counted as test runtime.

Next step: root freezes actual final source, obtains fresh production-version evidence, runs real default preflight, then follows the reviewed explicit Execute build path. Actual new APK/signature/device/publication/16 KiB compatibility are unclaimed. Review performed no real identity read, signing, build, device, remote or root/product write.

Exact Git-export folders are ignored and not committed. Retained evidence uses explicit byte-preserving attributes so JSON/log/report hashes survive checkout. `evidence-manifest.json` binds all retained evidence except itself.
