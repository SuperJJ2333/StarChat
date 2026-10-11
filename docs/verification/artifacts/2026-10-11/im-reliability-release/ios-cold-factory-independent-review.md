# Independent iOS database initialization gate review

2026-10-11, root; reviewed `df1b3e92f1c160bb1df7303ff5b2fb2d4b917936` after the separately reviewed production factory correction `9218be3720cd39128445691697787b371304bf58`.

Specification/domain: PASS. The two additional tests each use a fresh `Isolate.run`, so the sqflite worker initializer is not inherited from the preceding case. They open the real default metadata factory and the existing Matrix keyed factory in opposite orders. Both report a nonempty SQLCipher version. They persist synthetic values, close both handles, inspect the plain/encrypted file headers, reopen, reject an independently opened wrong-key connection and read both correct connections afterward. Merely constructing the keyed factory does not perform the first database open. The existing four native cases remain unchanged. The existing iOS CI target already executes this file.

Quality/security: PASS. This delta changes no production source, workflow, dependency, key policy, schema, or native storage protection. The temporary directory is created by the fixture itself and removed after handles close. Keys/data are synthetic; no network or credentials are used. `singleInstance: false` prevents wrong-key testing from accidentally reusing a correct connection. The test explicitly requires iOS. It does not inject, bypass, or claim validation of PendingMediaDirectory protection.

Validation: independent diff/source inspection and `git diff --check` passed. The implementer reports analyzer exit 0. No native execution was rerun during this review; final CI must provide that evidence. These tests cannot establish physical iPhone file protection, signed-entitlement correctness, or retention of an existing user's data during upgrade.
