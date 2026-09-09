# Moments reactions presentation

The user's 2026-09-09 UI request defines this change. Implement the same reaction area in feed, detail and personal timelines, retaining the existing shared identity and media providers.

- Background #333333, selected reply #292929, radius 8. Body #F2F2F2, names #C4D2EE, timestamps #B3B3B3. Dividers white at approximately 10% opacity. All text colors exceed 4.5:1 against the normal background.
- Comment avatar 30 logical pixels with existing avatar rounding/cache; name beside it; timestamp above content at the trailing edge. Detail padding 14 instead of feed 10. Content wraps at narrow widths and larger text scales. Inline emoji/media preserve existing selection and preview behavior.
- Other person's comment opens the shared reply composer and remains selected until dismissal. Own comment exposes Copy and Delete. Avatar/name targets open the corresponding profile without invoking the parent comment/post action.
- Liker avatars scroll horizontally without the former 20-person server truncation. The API supplies only the viewer's current allowed friends and self; visible counts match those rows. Hidden reply-target metadata is removed. Comment media URLs recheck the current audience at access time.
- Client projections additionally filter retained snapshots against current contacts and local Moments permissions. They are presentation subsets, never replacements for authoritative server data. A known privacy change clears cached authorization before another request finishes.
- Like feedback lasts 700 ms, combines a small heart bounce with six fading particles, and is disabled by the system reduced-motion setting. Like/unlike updates both count and avatar list immediately; failure restores reaction fields while preserving concurrent comments. Pending writes must remain coherent across navigation.
- Post separators use theme-aware divider colors plus a restrained shadow. Dark reaction containers apply in both themes.

No financial, authentication, Matrix encryption, schema or production deployment changes are part of this scope. Live-account tests are not needed for isolated UI and API regression coverage. Figma node 19:4 is the existing target; tool access is unavailable, so local HTML/registry alignment is recorded separately from remote synchronization.
