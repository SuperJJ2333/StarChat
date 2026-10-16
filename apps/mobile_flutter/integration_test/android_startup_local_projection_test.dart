import 'package:integration_test/integration_test.dart';
import '../test/core/startup_local_projection_entry_test.dart' as scenario;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenario.registerStartupProjectionEntryTests(report: (data) {
    binding.reportData = data;
  });
}
