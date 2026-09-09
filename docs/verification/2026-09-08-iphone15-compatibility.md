# iPhone 15 enterprise-package compatibility investigation

User reports same enterprise IPA works on iPad Air 13 and iPhone 8 iOS16.7.4; iPhone15 can send voice but cannot play sent/received voice, duplicate direct rooms, unreadable history after exit, and video send/play/receive problems. iPhone15 iOS version and USB connection remain pending.

USB metadata read identified currently connected device as iPhone10,1 / iOS16.7.4 / 20H240 (the working control). No content or device identifiers retained.

Source audit in isolated T:/ worktree:
- SQLCipher database is encrypted from creation. Reopen retains DB and keys; explicit reset deletes DB and key. No evidence reset was invoked on affected device.
- Native secure session differentiates errSecItemNotFound from other Keychain failures; other errors propagate. Database key generator creates a key only if read returns null. No evidence of a missing or changed key on affected device yet.
- Canonical direct-room open errors can fall back to normal room lookup/create; room repair returning null can trigger replacement. This is a possible duplication path, not confirmed root cause.
- Voice and video require successful Matrix attachment decryption before their local players initialize. Need distinguish download, decryption, format and audio-session errors.
- Enterprise package has previously recorded app-ID mismatch and two added libraries. Cross-device success does not prove or disprove their involvement.

No production/source behavior modified. Do not delete caches, reset DB, uninstall or merge/delete rooms during diagnosis. Next: identify affected phone/system, capture technical-only reproduction, then test-first bounded fixes with required security review if key persistence/E2EE behavior changes.
