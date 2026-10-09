import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test/features/matrix/cache_first_counts_test.dart' as cache_first;
import '../test/features/matrix/room_continuous_history_fling_test.dart'
    as continuous_history;
import '../test/features/matrix/room_page_lifecycle_test.dart' as lifecycle;

/// Synthetic native functional coverage; no user account or message data.
/// Debug execution is not a release/profile smoothness acceptance result.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  cache_first.cacheFirstDatabaseFactory = createDatabaseFactoryFfi(
    ffiInit: SQfLiteEncryptionHelper.ffiInit,
  );
  setUpAll(() => expect(Platform.isAndroid, isTrue));
  group('native cache-first SQLCipher functional paths', cache_first.main);
  group('native continuous fast history', continuous_history.main);
  group('native cached room lifecycle', lifecycle.main);
}
