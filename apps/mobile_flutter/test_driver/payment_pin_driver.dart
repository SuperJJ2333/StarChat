import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final directory = Platform.environment['PAYMENT_PIN_ARTIFACT_DIR'];
  if (directory == null ||
      directory.isEmpty ||
      !Directory(directory).isAbsolute) {
    throw StateError(
        'PAYMENT_PIN_ARTIFACT_DIR must name an absolute verification artifact directory.');
  }
  await Directory(directory).create(recursive: true);
  await integrationDriver(
    writeResponseOnFailure: true,
    responseDataCallback: (data) => writeResponseData(
      data == null ? null : (Map<String, dynamic>.of(data)..remove('screenshots')),
      destinationDirectory: directory,
      testOutputFilename: 'isolated-device-result',
    ),
    onScreenshot: (name, bytes, [args]) async {
      if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name)) return false;
      await File('$directory/$name.png').writeAsBytes(bytes, flush: true);
      return true;
    },
  );
}
