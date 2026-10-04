import 'package:crypto/crypto.dart';
import 'dart:convert';
import '../../core/business_auth_contracts.dart';
import 'phone_number_format.dart';

final class _Reservation {
  _Reservation(this.deadline);
  DateTime deadline;
}

/// Only deadlines live beyond a page. No OTP, proof or raw contact is retained.
final class OtpCooldown {
  OtpCooldown(this.owner, {DateTime Function()? now})
      : now = now ?? DateTime.now;
  final Object owner;
  final DateTime Function() now;
  static final _owners = Expando<Map<String, _Reservation>>();
  Map<String, _Reservation> get _entries => _owners[owner] ??= {};
  String? _key;
  _Reservation? _reservation;
  String? _reservationKey;
  bool get hasBoundTarget => _key != null;
  OtpCooldown snapshot() => OtpCooldown(owner, now: now)
    .._key = _key
    .._reservation = _reservation
    .._reservationKey = _reservationKey;

  void bind(
      {required String purpose,
      required String channel,
      required String target,
      bool authenticated = false}) {
    final normalized = channel == 'phone'
        ? normalizeMainlandPhone(target) ?? target.trim()
        : target.trim().toLowerCase();
    final epoch = authenticated && owner is BusinessSessionMonitor
        ? (owner as BusinessSessionMonitor).sessionEpoch
        : 0;
    _key = sha256
        .convert(
            utf8.encode('$authenticated|$epoch|$purpose|$channel|$normalized'))
        .toString();
    _entries.removeWhere((_, deadline) => !deadline.deadline.isAfter(now()));
  }

  int get remaining {
    final deadline = _entries[_key];
    if (deadline == null) return 0;
    return (deadline.deadline.difference(now()).inMilliseconds / 1000)
        .ceil()
        .clamp(0, 86400);
  }

  bool reserve([int seconds = 60]) {
    if (_key == null || remaining > 0) return false;
    _reservationKey = _key;
    _reservation = _Reservation(now().add(Duration(seconds: seconds)));
    _entries[_key!] = _reservation!;
    return true;
  }

  void extend(int seconds) {
    if (_key == null) return;
    final deadline = now().add(Duration(seconds: seconds));
    final existing = _entries[_key!];
    if (_reservation != null && !identical(existing, _reservation)) return;
    if (existing == null) {
      _entries[_key!] = _Reservation(deadline);
    } else if (deadline.isAfter(existing.deadline)) {
      existing.deadline = deadline;
    }
  }

  void reject() {
    if (_reservationKey != null &&
        identical(_entries[_reservationKey!], _reservation)) {
      _entries.remove(_reservationKey);
    }
  }
}
