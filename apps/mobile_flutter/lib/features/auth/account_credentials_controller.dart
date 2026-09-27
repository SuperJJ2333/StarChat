import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../core/business_api_error.dart';

/// Shared bounded-operation feedback; cooldown begins before the send attempt.
final class AccountCredentialsController extends ChangeNotifier {
  bool busy = false;
  int cooldown = 0;
  String? message;
  String? errorCode;
  Timer? _timer;
  bool _disposed = false;
  int _generation = 0;
  int get generation => _generation;
  bool isCurrent(int generation) =>
      !_disposed && busy && generation == _generation;
  void setMessage(String value) {
    message = value;
    _notify();
  }

  void clearCooldown() {
    _timer?.cancel();
    cooldown = 0;
    _notify();
  }

  void startCooldown([int seconds = 60]) {
    _timer?.cancel();
    cooldown = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      cooldown--;
      if (cooldown <= 0) timer.cancel();
      _notify();
    });
    _notify();
  }

  Future<bool> perform(Future<void> Function() action) async {
    if (busy || _disposed) return false;
    ++_generation;
    busy = true;
    message = null;
    errorCode = null;
    _notify();
    try {
      await action().timeout(const Duration(seconds: 8));
      return !_disposed;
    } on BusinessApiException catch (error) {
      if (!_disposed) errorCode = error.code;
      if (!_disposed) {
        message = error.statusCode >= 500
            ? '验证服务暂不可用，请稍后重试'
            : error.message == '业务请求失败'
                ? '验证请求未被接受，请重试'
                : error.message;
      }
    } catch (_) {
      if (!_disposed) message = '请求结果待确认，请稍后重试或联系客服';
    } finally {
      ++_generation;
      busy = false;
      _notify();
    }
    return false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
