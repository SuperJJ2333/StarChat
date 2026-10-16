import 'package:integration_test/integration_test.dart';
import '../test/core/startup_local_projection_entry_test.dart' as scenario;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final scenarios = <Map<String, Object>>[];
  scenario.registerStartupProjectionEntryTests(report: (data) {
    scenarios.add(data);
    binding.reportData = {
      'scenarios': scenarios,
      'completed_scenarios': scenarios.length
    };
  });
}
