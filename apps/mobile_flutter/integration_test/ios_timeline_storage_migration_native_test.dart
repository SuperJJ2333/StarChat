import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/features/matrix/timeline_storage_migration_test.dart'
    as migration_tests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('timeline storage migration gate runs on native iOS', () {
    expect(Platform.isIOS, isTrue,
        reason: 'Requires the linked iOS SQLCipher framework and isolates.');
  });

  migration_tests.main();
}
