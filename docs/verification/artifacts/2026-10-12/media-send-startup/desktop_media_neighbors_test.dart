import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../../apps/mobile_flutter/test/core/outbox/media_outbox_sdk_transaction_test.dart' as sdk;
import '../../../../../apps/mobile_flutter/test/features/matrix/media_outbox_coordinator_test.dart' as coordinator;

// Verification harness only. Existing test bodies are unmodified. This selects
// the real desktop SQLite worker, not an Android/iOS SQLCipher native gate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    sqfliteFfiInit();
    final desktop = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await desktop.close();
  });
  sdk.main();
  coordinator.main();
}
