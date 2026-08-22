# Avatar and Repository Remediation Implementation Plan

**Goal:** Eliminate Matrix avatar first-paint fallback flashes, load all group members for member grids and mosaics, and reduce local Git refs to `main`.

**Architecture:** Resolve authenticated Matrix thumbnail metadata synchronously when a logged-in Matrix client already supplies a token. Request joined members when rendering groups lacks a complete participant list, use `m.room.avatar` before a member mosaic, and retain default member tiles only when a member truly has no image. Preserve Git refs in a bundle before removing attached worktrees and non-main branches.

**Verification:** Flutter analyzer, focused matrix/UI tests, APK build/install/launch, remote Matrix/business health checks, and final Git ref/worktree enumeration.
