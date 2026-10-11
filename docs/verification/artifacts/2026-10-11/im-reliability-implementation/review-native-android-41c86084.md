# R8 Android lstat independent review

Frozen input: `41c86084f9accf9a0fa6eef26968ed47b63adbad`. Author `/root`; independent reviewer `/root/fix_scheduler_r6`. Reviewed exact Git blobs of the three changed files. Their author-worktree contents match the frozen blobs after CRLF normalization; both raw and Git-byte SHA256 identities are saved in `manifest.json`. Reviewer did not edit any root source/artifact.

## SPEC — PASS for this Android correction

Production validation now calls `android.system.Os.lstat`, with `OsConstants` type predicates. This removes the earlier unresolved dependence on Java NIO/desugaring at the configured API24 minimum; platform lstat is available from API21. Only ENOENT becomes an absent optional entry. Other errno failures propagate to the fixed channel error. Existing root checks still reject a symbolic link before creation, require a directory, and verify read/write access. Fixed manifest, SQLite sidecars and fixed source filenames are constrained by canonical containment and the expected regular-file/directory type. A dangling WAL/part has S_IFLNK, reaches validation and fails rather than disappearing behind a follow-link existence test.

The change does not accept paths from Dart, expand the channel input, delete/migrate files, alter E2EE, or change cache/pending ownership. Original directory-placeholder and dangling-optional-entry failures remain covered. No specification blocker found in this three-file correction.

## QUALITY / SECURITY — PASS for this Android correction

The production change is narrow and fails closed. The test-only Java NoFollowPosix shadow preserves the API24/25 static libcore method shape; the Kotlin NoFollowLinux shadow targets API26+ and keeps unrelated inherited framework behavior. Host Files.readAttributes with NOFOLLOW_LINKS supplies only the low-level stat contract; production root/ID/type/path logic remains the subject under test. Both shadows live under src/test, not a shipping source set. Their comment explicitly states the Robolectric behavior being modeled, so these tests must not be described as actual device lstat execution.

Author evidence checked and retained:

- `android-native-storage-api24-35-posix.txt` is the successful compile/test log. Its associated XML reports 12 tests, zero failures/errors/skips: six policy tests on each API24/API35 configuration. Exact XML and hashes are saved here.
- The misleadingly named earlier `android-native-storage-api24-35-final.txt` is a compile failure from an intermediate Kotlin static override; it is retained as such, not counted as a successful gate. The committed correction uses Java for that static shadow.
- `MediaStorageProbe.java` and `native-result.txt` show an actual Android OS-contract probe for regular file, directory, dangling symlink and ENOENT. Root identifies the device as API28; this reviewer inspected the synthetic source and PASS output, not a fresh device property query. The probe runs in /data/local/tmp and does not exercise app-private noBackup directory/channel, credential encryption or backup extraction.
- `git diff 41c86084^ 41c86084 --check` passed. Root source hashes match this frozen input. No duplicate Gradle run was started on unchanged inputs while root owns the shared build workspace.

No blocker found in this Android source correction. Remaining acceptance is explicit: real app-private integration/backup/locked-device behavior remains unverified here; same-process malicious atomic path replacement is outside the helper's asserted guarantee. This approval does not mark the complete cross-platform R8 gate green. Root has reported that all three current iOS XCTest assertions failed and is independently examining xcresult; the earlier Swift source review is not an iOS runtime PASS.