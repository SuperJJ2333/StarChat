/// Process-lifetime client quota for encrypted nudge sends.
///
/// This deliberately scopes the rolling window by Matrix sender and room. It
/// survives a [RoomPage] recreation, but is not a cross-device enforcement
/// mechanism; that would require a server-side encrypted-event policy.
final class NudgeRateLimiter {
  NudgeRateLimiter({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final shared = NudgeRateLimiter();
  static const window = Duration(seconds: 60);
  static const maxReservations = 3;

  final DateTime Function() _now;
  final Map<_NudgeQuotaKey, List<NudgeReservation>> _reservations = {};
  var _nextReservationId = 0;

  NudgeReservation? reserve(
      {required String senderId, required String roomId}) {
    final key = _NudgeQuotaKey(senderId, roomId);
    final now = _now();
    final entries = _reservations.putIfAbsent(key, () => <NudgeReservation>[]);
    entries.removeWhere((entry) => now.difference(entry.reservedAt) >= window);
    if (entries.length >= maxReservations) return null;
    final reservation = NudgeReservation._(key, now, ++_nextReservationId);
    entries.add(reservation);
    return reservation;
  }

  /// Releases exactly the failed send's token. A concurrent reservation never
  /// shares object identity and therefore cannot be removed accidentally.
  void release(NudgeReservation reservation) {
    final entries = _reservations[reservation._key];
    if (entries == null) return;
    entries.removeWhere((entry) => entry._id == reservation._id);
    if (entries.isEmpty) _reservations.remove(reservation._key);
  }
}

final class NudgeReservation {
  const NudgeReservation._(this._key, this.reservedAt, this._id);
  final _NudgeQuotaKey _key;
  final DateTime reservedAt;
  final int _id;
}

final class _NudgeQuotaKey {
  const _NudgeQuotaKey(this.senderId, this.roomId);
  final String senderId;
  final String roomId;

  @override
  bool operator ==(Object other) =>
      other is _NudgeQuotaKey &&
      other.senderId == senderId &&
      other.roomId == roomId;

  @override
  int get hashCode => Object.hash(senderId, roomId);
}
