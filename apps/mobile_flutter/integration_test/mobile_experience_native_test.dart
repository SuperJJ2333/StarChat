import 'mobile_history_native_test.dart' as history;
import 'reliability_media_native_test.dart' as media;

/// Android-only synthetic native gate for the experience candidate.
/// Dedicated native storage and history boundaries, all reported by testWidgets.
/// Host fake-clock algorithm suites keep their separate host gate.
/// It does not open the installed account or establish release performance SLOs.
void main() {
  media.main();
  history.main();
}
