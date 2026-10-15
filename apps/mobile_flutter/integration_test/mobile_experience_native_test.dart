import 'cache_first_fast_history_test.dart' as history;
import 'reliability_media_native_test.dart' as media;

/// Android-only synthetic native gate for the experience candidate.
/// Reuses the real storage/SQLCipher and engine suites in one rebuilt Debug APK.
/// It does not open the installed account or establish release performance SLOs.
void main() {
  media.main();
  history.main();
}
