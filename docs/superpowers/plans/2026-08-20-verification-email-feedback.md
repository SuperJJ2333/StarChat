# 验证邮箱反馈优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or superpowers:subagent-driven-development) to implement this plan task-by-task.

**Goal:** 在验证邮箱页采用 B 方案显示验证码错误，并增加不阻塞点击的 150ms 按压缩放反馈。

**Architecture:** 控制器把验证码接口错误转换为 `fieldErrors['code']`，并提供输入变化时清除该字段错误的公开方法；页面在输入框上方渲染错误横幅。现有 `ModernActionButton` 保持回调契约，仅将按压动画调整为 150ms，并用现有手势状态覆盖触摸、鼠标和键盘语义。

**Tech Stack:** Flutter/Dart, Cupertino widgets, ChangeNotifier, Flutter widget tests.

---

### Task 1: 控制器验证码错误状态

**Files:**
- Modify: `apps/mobile_flutter/lib/features/auth/registration_controller.dart`
- Test: `apps/mobile_flutter/test/features/auth/registration_controller_test.dart`

- [ ] **Step 1: Write the failing tests**

增加一个 gateway 在 `verifyEmail` 抛出 `BusinessApiException(code: 'EMAIL_VERIFICATION_CODE_INVALID', ...)` 的测试，断言 `verifyCode` 不向外抛出，并产生 `state.fieldErrors['code'] == '验证码错误，请重新输入'`。随后调用 `clearVerificationCodeError()`，断言 code 错误被移除而其他状态字段保留。

- [ ] **Step 2: Run the focused test and verify it fails**

Run from `apps/mobile_flutter`:
`C:\src\flutter\bin\flutter.bat test test/features/auth/registration_controller_test.dart --plain-name "verification code error is stored and can be cleared"`

Expected: FAIL because `verifyCode` currently propagates `BusinessApiException` and no `clearVerificationCodeError` exists.

- [ ] **Step 3: Implement the minimal controller behavior**

Wrap `_verify` in `try/catch` for `BusinessApiException`; map `EMAIL_VERIFICATION_CODE_INVALID` and `EMAIL_VERIFICATION_INVALID` to `RegistrationState.failed` with the current session and code error text. Add `clearVerificationCodeError()` that copies the current state and removes only `fieldErrors['code']`; add a private `_withoutCodeError` helper if needed. Preserve the session and resend countdown so the verify button remains enabled.

- [ ] **Step 4: Run the focused test and verify it passes**

Run the same Flutter command; expected `1 passed`.

### Task 2: Error banner and live clearing on the verification page

**Files:**
- Modify: `apps/mobile_flutter/lib/features/auth/verification_page.dart`
- Test: `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`

- [ ] **Step 1: Write the failing widget test**

Build `VerificationPage` with a gateway that returns the verification-code error, tap `auth-verification-verify`, and assert a `Key('auth-verification-code-error')` and exact text `验证码错误，请重新输入` appear above the `CupertinoTextField`. Enter a changed code and assert the error text disappears while `auth-verification-verify` remains present.

- [ ] **Step 2: Run the focused widget test and verify it fails**

Run from `apps/mobile_flutter`:
`C:\src\flutter\bin\flutter.bat test test/features/auth/auth_pages_test.dart --plain-name "verification shows code error above field and clears on edit"`

Expected: FAIL because the page currently has no error banner, no controller listener on text edits, and `verify()` does not handle the controller error state.

- [ ] **Step 3: Implement the page rendering and listener**

Attach a `TextEditingController` listener in `initState`; when text changes call `widget.controller.clearVerificationCodeError()`. In the column, render `state.fieldErrors['code']` before the `CupertinoTextField` using a `Container` with light red fill, red border/text, `fontSize: 14`, and the error key. Keep `ModernActionButton.onPressed: verify` unconditionally enabled.

- [ ] **Step 4: Run the focused widget test and verify it passes**

Run the same Flutter command; expected `1 passed`.

### Task 3: 150ms button press animation

**Files:**
- Modify: `apps/mobile_flutter/lib/ui/components/modern_action_button.dart`
- Test: `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`

- [ ] **Step 1: Write the failing animation assertion**

Pump the verification page, send a pointer-down to `auth-verification-verify`, pump briefly, and assert the button subtree `Transform` scale is approximately `0.98`; release and pump 150ms, then assert scale returns to `1.0`. Keep a callback counter to prove the tap callback still fires.

- [ ] **Step 2: Run the focused animation test and verify it fails**

Run:
`C:\src\flutter\bin\flutter.bat test test/features/auth/auth_pages_test.dart --plain-name "verification button provides a nonblocking press scale"`

Expected: FAIL on the 150ms timing/scale assertion because the shared button currently uses 100ms.

- [ ] **Step 3: Implement the minimal animation change**

Change only the enabled pressed `AnimatedScale.duration` from `100ms` to `150ms`; retain `.98`, `Curves.easeOut`, reduced-motion handling, and existing `onTapUp` callback order.

- [ ] **Step 4: Run focused and regression tests**

Run:
`C:\src\flutter\bin\flutter.bat test test/features/auth/registration_controller_test.dart test/features/auth/auth_pages_test.dart`

Expected: all auth tests pass, including the new error and animation tests.

### Task 4: Verification and evidence

**Files:**
- Modify: `docs/verification/2026-08-19-registration-server-activation.md`

- [ ] **Step 1: Run Flutter analyze**

Run:
`C:\src\flutter\bin\flutter.bat analyze --no-pub lib/features/auth/registration_controller.dart lib/features/auth/verification_page.dart lib/ui/components/modern_action_button.dart`

Expected: `No issues found!`.

- [ ] **Step 2: Run repository verification**

Run:
`pwsh -NoProfile -File scripts/verify.ps1`

Expected: repository policy PASS, Flutter/auth tests PASS, and final `Verification: PASS`.

- [ ] **Step 3: Record exact evidence**

Append the focused test, analyze, and full verification commands with literal outputs and exit status to the verification document. Do not add artifacts to the repository root.
