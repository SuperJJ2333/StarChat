# Matrix Chat Avatar Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Restore private and group chat member images by resolving Matrix `mxc://` avatar identifiers to authorized thumbnail requests before the existing cache consumes them.

**Architecture:** A small pure resolver converts HTTP(S) unchanged and builds Matrix thumbnail URLs for `mxc://` URIs. `MatrixUserAvatar` asynchronously resolves a member URI using the active Matrix client and supplies the resulting URL plus authorization header to the existing cache-backed `UserAvatar`; no token is embedded in cache keys or URLs.

**Tech Stack:** Flutter/Dart, matrix 0.34, cached_network_image, flutter_test.

---

### Task 1: URL-resolution regression tests

- [x] Add tests proving HTTPS URLs stay unchanged, authenticated Matrix media uses `/_matrix/client/v1/media/thumbnail` and an Authorization header, and legacy media uses the v3 endpoint without a header.
- [x] Run the test and record RED because the resolver did not exist.
- [x] Implement the pure resolver and run the tests GREEN.

### Task 2: Connect chat surfaces to resolved avatars

- [x] Add a Matrix-aware avatar widget which resolves `mxc://` asynchronously and delegates image cache behavior to `UserAvatar`.
- [x] Use it for direct conversation rows, group mosaics, folded-group rows, and chat timeline message avatars; preserve contacts/profile HTTP avatar fallback.
- [x] Permit the shared cache image provider to receive the Matrix authorization header without placing it in a cache key.
- [x] Replace group-info’s scheme filtering so member avatar source data is retained for the next Matrix-aware surface migration.

### Task 3: Verification and delivery

- [x] Run Flutter analyze and focused matrix/UI tests.
- [x] Build and install debug APK on `emulator-5554`.
- [x] Append test/build/install outcomes to `docs/verification/2026-08-19-registration-server-activation.md`.

