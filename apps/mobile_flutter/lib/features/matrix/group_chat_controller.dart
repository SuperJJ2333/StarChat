import 'package:flutter/foundation.dart';
import 'package:characters/characters.dart';

import '../contacts/contact_models.dart';

abstract interface class GroupChatGateway {
  Future<String> createEncryptedGroupChat({
    required String name,
    required List<String> matrixUserIds,
  });
}

abstract interface class GroupChatBackend {
  Future<String> createPrivateEncryptedRoom({
    required String name,
    required List<String> matrixUserIds,
  });

  Future<void> waitUntilJoined(String roomId);
}

final class GroupChatService implements GroupChatGateway {
  const GroupChatService(this.backend);

  final GroupChatBackend backend;

  @override
  Future<String> createEncryptedGroupChat({
    required String name,
    required List<String> matrixUserIds,
  }) async {
    final uniqueInvitees = matrixUserIds.toSet().toList(growable: false);
    if (uniqueInvitees.length < 2) {
      throw ArgumentError.value(
        matrixUserIds,
        'matrixUserIds',
        '群聊至少需要选择两位好友',
      );
    }
    final roomId = await backend.createPrivateEncryptedRoom(
      name: name,
      matrixUserIds: uniqueInvitees,
    );
    await backend.waitUntilJoined(roomId);
    return roomId;
  }
}

enum GroupChatStatus { idle, loading, ready, creating, created, failed }

final class GroupChatState {
  const GroupChatState({
    this.status = GroupChatStatus.idle,
    this.contacts = const [],
    this.selectedMatrixUserIds = const {},
    this.message,
  });

  final GroupChatStatus status;
  final List<ContactSummary> contacts;
  final Set<String> selectedMatrixUserIds;
  final String? message;
}

final class GroupChatController extends ChangeNotifier {
  GroupChatController({
    required this.contacts,
    required this.groups,
    required this.currentUserDisplayName,
  });

  final ContactsGateway contacts;
  final GroupChatGateway groups;
  final String currentUserDisplayName;
  GroupChatState state = const GroupChatState();

  bool get canCreate =>
      state.status != GroupChatStatus.creating &&
      state.selectedMatrixUserIds.length >= 2;

  Future<void> load() async {
    _set(GroupChatState(
      status: GroupChatStatus.loading,
      contacts: state.contacts,
      selectedMatrixUserIds: state.selectedMatrixUserIds,
    ));
    try {
      _set(GroupChatState(
        status: GroupChatStatus.ready,
        contacts: await contacts.listContacts(),
        selectedMatrixUserIds: state.selectedMatrixUserIds,
      ));
    } catch (_) {
      _set(const GroupChatState(
        status: GroupChatStatus.failed,
        message: '通讯录加载失败，请重试',
      ));
    }
  }

  void toggle(String matrixUserId) {
    if (state.status == GroupChatStatus.creating) return;
    final selected = Set<String>.of(state.selectedMatrixUserIds);
    selected.contains(matrixUserId)
        ? selected.remove(matrixUserId)
        : selected.add(matrixUserId);
    _set(GroupChatState(
      status: GroupChatStatus.ready,
      contacts: state.contacts,
      selectedMatrixUserIds: selected,
    ));
  }

  Future<String?> create(String requestedName) async {
    if (!canCreate) return null;
    final invitees = state.selectedMatrixUserIds.toList(growable: false);
    final selectedNames = state.contacts
        .where((contact) => invitees.contains(contact.matrixUserId))
        .map((contact) => contact.displayName);
    final fallbackName = [
      currentUserDisplayName.trim().isEmpty ? '我' : currentUserDisplayName,
      ...selectedNames,
    ].take(3).join('、');
    final rawName =
        requestedName.trim().isEmpty ? fallbackName : requestedName.trim();
    final name = rawName.characters.take(20).toString();
    _set(GroupChatState(
      status: GroupChatStatus.creating,
      contacts: state.contacts,
      selectedMatrixUserIds: state.selectedMatrixUserIds,
    ));
    try {
      final roomId = await groups.createEncryptedGroupChat(
        name: name,
        matrixUserIds: invitees,
      );
      _set(GroupChatState(
        status: GroupChatStatus.created,
        contacts: state.contacts,
        selectedMatrixUserIds: state.selectedMatrixUserIds,
      ));
      return roomId;
    } catch (_) {
      _set(GroupChatState(
        status: GroupChatStatus.failed,
        contacts: state.contacts,
        selectedMatrixUserIds: state.selectedMatrixUserIds,
        message: '群聊创建失败，请检查网络后重试',
      ));
      return null;
    }
  }

  void _set(GroupChatState next) {
    state = next;
    notifyListeners();
  }
}
