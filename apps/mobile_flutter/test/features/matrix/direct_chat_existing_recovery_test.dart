import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

void main() {
  test(
      'uncertain creation recovery never creates when SDK has no existing room',
      () async {
    final client = Client('recover-existing-only');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'));
    addTearDown(matrix.suspend);
    expect(await matrix.findExistingDirectChat('@peer:test'), isNull);
    expect(client.rooms, isEmpty);
  });
}
