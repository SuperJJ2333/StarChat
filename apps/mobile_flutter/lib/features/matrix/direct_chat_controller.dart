import 'package:flutter/foundation.dart';

final class DirectChatRoom {
  const DirectChatRoom({
    required this.roomId,
    required this.encrypted,
    required this.joinedMemberCount,
    required this.participantIds,
  });
  final String roomId;
  final bool encrypted;
  final int joinedMemberCount;
  final Set<String> participantIds;
}

abstract interface class DirectChatBackend {
  Future<DirectChatRoom?> findJoinedDirectRoom(String matrixUserId);
  Future<String> createEncryptedDirectRoom(String matrixUserId);
  Future<DirectChatRoom> waitForRoom(String roomId);
}

abstract interface class DirectChatGateway {
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId);
}

final class DirectChatService implements DirectChatGateway {
  const DirectChatService(this.backend);
  final DirectChatBackend backend;

  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) async {
    final existing = await backend.findJoinedDirectRoom(matrixUserId);
    if (existing != null) return _requireSafe(existing, matrixUserId);
    final roomId = await backend.createEncryptedDirectRoom(matrixUserId);
    return _requireSafe(await backend.waitForRoom(roomId), matrixUserId);
  }

  DirectChatRoom _requireSafe(DirectChatRoom room, String matrixUserId) {
    if (!room.encrypted ||
        room.joinedMemberCount != 2 ||
        room.participantIds.length != 2 ||
        !room.participantIds.contains(matrixUserId)) {
      throw StateError('Direct chat must be encrypted and contain two members');
    }
    return room;
  }
}

enum DirectChatState { idle, opening, ready, failed }

final class DirectChatController extends ChangeNotifier {
  DirectChatController(this.gateway);
  final DirectChatGateway gateway;
  DirectChatState state = DirectChatState.idle;
  Object? error;
  String? _lastMatrixUserId;
  final Map<String, Future<DirectChatRoom>> _openings = {};

  Future<DirectChatRoom> open(String matrixUserId) async {
    final pending = _openings[matrixUserId];
    if (pending != null) return pending;
    _lastMatrixUserId = matrixUserId;
    state = DirectChatState.opening;
    error = null;
    notifyListeners();
    final opening = gateway.openOrCreateDirectChat(matrixUserId);
    _openings[matrixUserId] = opening;
    try {
      final room = await opening;
      state = DirectChatState.ready;
      notifyListeners();
      return room;
    } catch (failure) {
      state = DirectChatState.failed;
      error = failure;
      notifyListeners();
      rethrow;
    } finally {
      if (identical(_openings[matrixUserId], opening)) {
        _openings.remove(matrixUserId);
      }
    }
  }

  Future<DirectChatRoom> retry() {
    final matrixUserId = _lastMatrixUserId;
    if (matrixUserId == null) throw StateError('No direct chat to retry');
    return open(matrixUserId);
  }
}
