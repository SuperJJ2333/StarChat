import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_verification_page.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_verification_service.dart';
import 'package:matrix/matrix.dart';

final class _FailingSasRequest implements MatrixSasRequestHandle {
  @override
  Future<void> accept() async => throw StateError('secret-sdk-detail');
  @override
  Future<void> confirmSas() async {}
  @override
  Future<void> continueSas() async {}
  @override
  void dispose() {}
  @override
  Future<void> reject() async {}
}

void main() {
  testWidgets('verification action failure uses a fixed safe message',
      (tester) async {
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast();
    final matrix = MatrixSdkE2eeClient(
      Client('verification-page'),
      homeserver: Uri.parse('https://matrix.test'),
    );
    final service = MatrixVerificationService(
      matrix,
      incomingRequests: () => incoming.stream,
      requestIdFactory: () => 'opaque-request',
    );
    await tester.pumpWidget(CupertinoApp(
      home: MatrixVerificationPage(
        matrix: matrix,
        serviceFactory: (_) => service,
      ),
    ));
    await tester.pump();
    incoming.add(_FailingSasRequest());
    await tester.pump();

    await tester.tap(find.text('接受验证'));
    await tester.pump();

    expect(find.text('验证操作失败，请重试'), findsOneWidget);
    expect(find.textContaining('secret-sdk-detail'), findsNothing);
    await incoming.close();
  });

  testWidgets('immediate widget removal drains pending verification setup',
      (tester) async {
    var listens = 0;
    var cancels = 0;
    final incoming = StreamController<MatrixSasRequestHandle>.broadcast(
      onListen: () => listens++,
      onCancel: () => cancels++,
    );
    final suspendStarted = Completer<void>();
    final allowSuspend = Completer<void>();
    final matrix = MatrixSdkE2eeClient(
      Client('verification-page'),
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {
        suspendStarted.complete();
        await allowSuspend.future;
      },
      resumeClient: () async => Client('verification-resumed'),
    );
    final suspension = matrix.suspend();
    await suspendStarted.future;
    final service = MatrixVerificationService(
      matrix,
      incomingRequests: () => incoming.stream,
    );
    await tester.pumpWidget(CupertinoApp(
      home: MatrixVerificationPage(
        matrix: matrix,
        serviceFactory: (_) => service,
      ),
    ));
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));

    allowSuspend.complete();
    await suspension;
    await tester.pumpAndSettle();

    expect(listens, cancels);
    await incoming.close();
  });
}
