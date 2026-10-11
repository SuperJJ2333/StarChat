import 'package:matrix/matrix.dart' show SQfLiteEncryptionHelper;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Loads the already packaged SQLCipher library for local metadata databases.
/// sqflite_common_ffi shares one worker: its first factory selects the library.
/// Every production opener must therefore supply the same initializer, even
/// when metadata opens before the encrypted Matrix database on cold startup.
/// This selects a native library only. Callers retain their existing schema,
/// key policy and file format; no key or migration is applied here.
final DatabaseFactory localMetadataDatabaseFactory =
    createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
