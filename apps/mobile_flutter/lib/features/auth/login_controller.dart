import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/business_api_client.dart';

typedef LoginOperation=Future<void> Function(String username,String password);
enum LoginStatus { idle, loading, succeeded, failed }
final class LoginAuthenticationException implements Exception { const LoginAuthenticationException(); }
final class LoginState { const LoginState(this.status,{this.message}); final LoginStatus status; final String? message; }

final class LoginController extends ChangeNotifier {
  LoginController({required this.operation,Future<void> Function(Duration)? delay}):delay=delay??Future.delayed;
  final LoginOperation operation; final Future<void> Function(Duration) delay;
  LoginState state=const LoginState(LoginStatus.idle); String? _username,_password;
  Future<bool> submit(String username,String password) async { if(state.status==LoginStatus.loading)return false;_username=username;_password=password;state=const LoginState(LoginStatus.loading);notifyListeners();for(var attempt=0;attempt<3;attempt++){try{await operation(username,password);state=const LoginState(LoginStatus.succeeded);notifyListeners();return true;}on LoginAuthenticationException{state=const LoginState(LoginStatus.failed,message:'用户名或密码错误');notifyListeners();return false;}on BusinessApiException catch(error){state=LoginState(LoginStatus.failed,message:error.statusCode==401?'用户名或密码错误':error.message);notifyListeners();return false;}on SocketException catch(_){if(attempt<2){await delay(Duration(milliseconds:250*(1<<attempt)));continue;}state=const LoginState(LoginStatus.failed,message:'网络连接不稳定，请重试');notifyListeners();return false;}on TimeoutException catch(_){if(attempt<2){await delay(Duration(milliseconds:250*(1<<attempt)));continue;}state=const LoginState(LoginStatus.failed,message:'网络连接不稳定，请重试');notifyListeners();return false;}on http.ClientException catch(_){if(attempt<2){await delay(Duration(milliseconds:250*(1<<attempt)));continue;}state=const LoginState(LoginStatus.failed,message:'网络连接不稳定，请重试');notifyListeners();return false;}catch(_){state=const LoginState(LoginStatus.failed,message:'服务暂时不可用，请稍后重试');notifyListeners();return false;}}return false;}
  Future<bool> retryNow()=>submit(_username??'',_password??'');
}
