import 'package:flutter/foundation.dart';

enum MessageDecryptionState { decrypting, decrypted, missingKey, failed }

@immutable
final class MatrixDecryptionUpdate {
  const MatrixDecryptionUpdate(this.eventId, this.state, {this.eventCode});
  final String eventId;
  final MessageDecryptionState state;
  final String? eventCode;
}

final class DecryptionEntry {
  const DecryptionEntry(this.state, {this.eventCode});
  final MessageDecryptionState state;
  final String? eventCode;
}

/// Tracks the UI state independently from the Matrix event type. Matrix keeps
/// an encrypted placeholder until a room key arrives; this controller lets a
/// late key update the conversation without rebuilding from stale text.
final class DecryptionStateController extends ChangeNotifier {
  final Map<String, DecryptionEntry> _entries = {};

  DecryptionEntry stateFor(String eventId) =>
      _entries[eventId] ??
      const DecryptionEntry(MessageDecryptionState.decrypting);

  DecryptionEntry? knownStateFor(String eventId) => _entries[eventId];

  void markDecrypting(String eventId) =>
      _set(eventId, const DecryptionEntry(MessageDecryptionState.decrypting));

  void markDecrypted(String eventId) =>
      _set(eventId, const DecryptionEntry(MessageDecryptionState.decrypted));

  void markMissingKey(String eventId,
          {String eventCode = 'MISSING_ROOM_KEY'}) =>
      _set(
          eventId,
          DecryptionEntry(MessageDecryptionState.missingKey,
              eventCode: eventCode));

  void markFailed(String eventId, {String eventCode = 'DECRYPTION_FAILED'}) =>
      _set(eventId,
          DecryptionEntry(MessageDecryptionState.failed, eventCode: eventCode));

  void retry(String eventId) => markDecrypting(eventId);

  void lateKeyReceived(String eventId) => markDecrypted(eventId);

  void _set(String eventId, DecryptionEntry entry) {
    final previous = _entries[eventId];
    if (previous?.state == MessageDecryptionState.decrypted &&
        entry.state != MessageDecryptionState.decrypted) {
      return;
    }
    _entries[eventId] = entry;
    notifyListeners();
  }
}
