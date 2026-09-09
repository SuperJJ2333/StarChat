# Moments correction contract

The user's Redmi feedback supersedes the fixed-dark design in the previous revision.

- Reactions use the navigation theme surface (#F7F7F7 light / #191919 dark); selection uses a deeper theme surface (#EDEDED / #111111). Foreground and separators resolve their light/dark roles at paint time.
- Feed, personal feed and detail use the same comment interaction function. Other comments open the reply composer in place and retain selection until it closes. Own comments open Copy/Delete. Blank reaction area taps and long presses do not bubble to post navigation/actions. Person and media targets retain their own interactions.
- Comment changes merge into the current item and must not overwrite newer likes; results from an obsolete privacy revision are discarded. Existing viewer-relative stranger filtering remains in all three pages.
- User and friend profiles use the same bounded identity card: 72px avatar, 16px horizontal gap, responsive name/account column and intrinsic header height. Eligible nonfriends have only Add to Contacts; self/friend/pending states cannot issue invalid requests. The action opens the existing request form.
- HTML mirrors the shared structure and theme roles. The user-profile catalog variant increases local registration to 331 screens; shared profile component registration raises the component count to 19. Existing Figma node identities are retained and remote synchronization is explicitly pending tool availability.

Delivery continues the user's Redmi Debug verification workflow, using the fixed APK rebuild/signing process and preserving app data. No production server or release-channel deployment is included.
