import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';

void main() {
  test('masked phone survives profile snapshot decoding and persistence', () {
    final snapshot = ProfileSnapshot.fromJson({
      'profile': {
        'username': 'alice',
        'nickname': 'Alice',
        'masked_email': 'a***@test.example',
        'masked_phone': '138****0000',
        'fallback_seed': 'stable-uuid'
      },
      'contacts': <Object>[],
    })!;
    expect(
        (snapshot.toJson()['profile'] as Map)['masked_phone'], '138****0000');
  });
}
