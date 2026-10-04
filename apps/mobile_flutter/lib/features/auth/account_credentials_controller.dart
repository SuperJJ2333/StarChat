import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../core/business_api_error.dart';
import 'otp_cooldown.dart';

/// A rejected request cannot have delivered a code. Unknown results retain the
/// send cooldown because retrying could send twice.
bool isRejectedCodeRequest(BusinessApiException error) =>
    (error.statusCode >= 400 &&
        error.statusCode < 500 &&
        error.statusCode != 408 &&
        error.statusCode != 429) ||
    const {
      'PHONE_AUTH_DISABLED',
      'SMS_NOT_CONFIGURED',
      'SMS_SEND_REJECTED',
      'SMS_SEND_FAILED'
    }.contains(error.code);

/// Shared bounded-operation feedback; cooldown begins before the send attempt.
final class AccountCredentialsController extends ChangeNotifier
    with WidgetsBindingObserver {
  AccountCredentialsController({Object? owner})
      : _cooldown = OtpCooldown(owner ?? Object()) {
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick();
  }

  final OtpCooldown _cooldown;
  void bindCooldown(
      {required String purpose,
      required String channel,
      required String target,
      bool authenticated = false}) {
    _cooldown.bind(
        purpose: purpose,
        channel: channel,
        target: target,
        authenticated: authenticated);
    _tick();
    _startTicker();
  }

  bool reserveCooldown() {
    final accepted = _cooldown.reserve();
    _tick();
    _startTicker();
    return accepted;
  }

  void _tick() {
    cooldown = _cooldown.remaining;
    _notify();
  }

  void _startTicker() {
    _timer?.cancel();
    if (_cooldown.remaining == 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      _tick();
      if (cooldown == 0) timer.cancel();
    });
  }

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

  void rejectCooldown() {
    _cooldown.reject();
    _tick();
  }

  void clearCooldown() {
    // Stage changes select a different key; retain the old stage deadline.
    cooldown = 0;
    _timer?.cancel();
    _notify();
  }

  void startCooldown([int seconds = 60]) {
    _cooldown.extend(seconds);
    _tick();
    _startTicker();
  }

  Future<bool> perform(Future<void> Function() action,
      {bool sendingCode = false}) async {
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
      if (!_disposed && sendingCode && isRejectedCodeRequest(error)) {
        _cooldown.reject();
        _tick();
      }
      if (!_disposed && sendingCode && error.statusCode == 429) {
        startCooldown(error.retryAfterSeconds ?? 60);
      }
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
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}
