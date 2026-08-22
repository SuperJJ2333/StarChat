# Avatar Stability and Group Mosaic Implementation Plan

**Goal:** Prevent avatar blank frames during Matrix URI resolution and ensure group mosaics retain a default-avatar tile for every selected member.

**Architecture:** `MatrixUserAvatar` shares resolved `mxc://` thumbnail metadata per Matrix client/URI/size and keeps a stable fallback visible while first pixels decode. `GroupAvatarMosaic` continues to receive one widget per joined member and renders each cell at fixed size; its tests cover members without remote avatar URLs.

### Task 1: Avatar loading stability
- [ ] Add regression tests for initial fallback and shared Matrix avatar resolution.
- [ ] Make resolution deduplicated and cache its result per input identity.
- [ ] Keep fallback visible until the remote image emits its first frame.

### Task 2: Group defaults
- [ ] Add a mosaic test with both a network avatar and a `UserAvatar` default tile.
- [ ] Preserve all supplied member tiles, including default-avatar widgets, within the first nine slots.

### Task 3: Verification
- [ ] Run focused Flutter tests/analyze, full verification, build and install the APK on `emulator-5554`; append evidence to `docs/verification/2026-08-19-registration-server-activation.md`.
