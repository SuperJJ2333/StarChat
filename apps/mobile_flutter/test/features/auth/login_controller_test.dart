import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';

void main() {
  test('network failures are retried up to three attempts', () async {
    var attempts=0;
    final controller=LoginController(operation:(_,__) async { attempts++; if(attempts<3) throw const SocketException('offline'); }, delay:(_)=>Future.value());
    await controller.submit('user','password');
    expect(attempts,3);
    expect(controller.state.status,LoginStatus.succeeded);
  });
  test('authentication failure is not retried', () async {
    var attempts=0;
    final controller=LoginController(operation:(_,__) async { attempts++; throw const LoginAuthenticationException(); },delay:(_)=>Future.value());
    await controller.submit('user','wrong');
    expect(attempts,1);
    expect(controller.state.message,'用户名或密码错误');
  });
}
