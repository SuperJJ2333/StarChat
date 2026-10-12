# DPAPI serialized-text normalization: independent review

Decision: **PASS for the one-line format correction** in root wrapper SHA `eef1c12edf36c800166447911e6cc08f56ebb53224d7b24a40670ea07d1413a4`. Integrate this test/evidence commit together with the release owner's separate wrapper fix. This checkout deliberately retains the original wrapper; running the new case against that original still fails.

## Specification / domain review

The observed input is a DPAPI serialized ciphertext text file with a terminal newline. `Get-Content -Raw` preserves it, and the direct `ConvertTo-SecureString` parse fails. The correction trims the serialized text before conversion; it does not trim or replace the decoded password. A real Windows DPAPI roundtrip with synthetic ciphertext plus CRLF reproduces the original FormatException. The synthetic password includes leading and trailing spaces, which must survive decryption unchanged.

## Quality / security review

Byte comparison independently confirms exactly one expression changed: `(Get-Content -LiteralPath $taskDpapi -Raw -Encoding utf8).Trim() | ConvertTo-SecureString`. Fixed P12 path/alias, public fingerprint and RSA checks, path/output protections, process environment password channel, signer-count/v2/v3 verification, and cleanup are unchanged. No new cryptographic format, key or fallback is introduced. Empty/invalid encoded text still cannot yield a valid P12 identity merely through this normalization.

The new test parses the candidate AST and executes only its actual DPAPI assignment against a synthetic file under a temporary fake USERPROFILE. It never executes the real signing flow, accesses actual signing material, or prints the decoded synthetic value. It checks no signer marker/output and frees the BSTR and SecureStrings. The candidate override is in the Python test harness only; it adds no production environment override.

## Evidence

- Original frozen wrapper `1baf91b7c2e3ed7951c3c3f9fab623d9cf6355d3dc3a2eade29f58508183b7d0`: one intended format-test RED, exit 1, System.FormatException; [log](dpapi-format-red.log) and [receipt](dpapi-format-red-receipt.json).
- Root corrected wrapper: all **19 synthetic cases PASS**, 0 skip, exit 0; [log](dpapi-format-green.log) and [receipt](dpapi-format-green-receipt.json). No candidate hash change during the run.
- Parent reviewer's separate execution of the new DPAPI format case: **1 PASS**, exit 0, 0.618 seconds reported by unittest; [log](dpapi-format-independent.log) and [receipt](dpapi-format-independent-receipt.json). The fixed wrapper hash was independently checked before and after.
- Test SHA `7cb68309598f3e92c215600e0c5efbe161d001b095485ab3f84c7506267d3f3d`; [method and reproduction](dpapi-format-notes.md).

The original `tool-evidence-identities.json` remains the immutable snapshot of restoration commit `7f881d596c70b520d613e4a2b281151452f9c96b`. It is not rewritten to pretend the subsequent test extension existed then. This follow-up's inputs and evidence are bound in `dpapi-format-review.json`. Root's actual identity-loading and APK-signing receipts remain separate; this reviewer did not access the real password/P12, sign, use ADB, or perform remote actions.
