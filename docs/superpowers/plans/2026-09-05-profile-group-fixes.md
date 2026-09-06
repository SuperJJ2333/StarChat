# Friend profile and group message fixes

Approved scope: user's five reported bugs on 2026-09-05; include in the pending ARM64 release. Existing permission to defer Figma applies.

1. Root owns `room_page.dart`: message action callback, public avatar propagation, viewer-owned friend remarks, and stranger avatar navigation. The profile entry agent owns `app_home.dart`, `matrix_home_page.dart`, and entry tests.
2. Prove missing callback/avatar/remark/navigation with failing regression checks before changing production code.
3. Reuse the canonical encrypted direct-chat controller. Render only the viewer's own contact remark; never publish private remarks or tags. Reuse group-member public-profile navigation for message avatars.
4. Run focused Flutter tests, analysis, and relevant repository checks. Review specification compliance before quality/security review.
5. Record evidence under `docs/verification/artifacts/2026-09-05/profile-group-fixes/`; incorporate fixes in the previously authorized signed ARM64 release.
