import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/business_api_client.dart';

abstract interface class ChatTransferDetailGateway {
  int get sessionEpoch;
  Stream<void> get sessionInvalidations;
  Future<Map<String, dynamic>> detail(String transferId);
  Future<Map<String, dynamic>> accept(String transferId);
  Future<Map<String, dynamic>> decline(String transferId);
}

final class BusinessChatTransferDetailGateway
    implements ChatTransferDetailGateway {
  const BusinessChatTransferDetailGateway(this.api);

  final BusinessApiClient api;

  @override
  int get sessionEpoch => api.sessionEpoch;

  @override
  Stream<void> get sessionInvalidations => api.sessionInvalidations.map((_) {});

  @override
  Future<Map<String, dynamic>> accept(String transferId) =>
      api.acceptChatTransfer(transferId);

  @override
  Future<Map<String, dynamic>> decline(String transferId) =>
      api.declineChatTransfer(transferId);

  @override
  Future<Map<String, dynamic>> detail(String transferId) =>
      api.chatTransferDetail(transferId);
}

enum ChatTransferDetailPhase { idle, loading, ready, failed, ended }

final class ChatTransferDetailState {
  const ChatTransferDetailState({
    this.phase = ChatTransferDetailPhase.idle,
    this.detail,
    this.message,
  });

  final ChatTransferDetailPhase phase;
  final Map<String, dynamic>? detail;
  final String? message;

  bool get ended => phase == ChatTransferDetailPhase.ended;
  bool get loading => phase == ChatTransferDetailPhase.loading;

  ChatTransferDetailState copyWith({
    ChatTransferDetailPhase? phase,
    Map<String, dynamic>? detail,
    String? message,
    bool clearDetail = false,
    bool clearMessage = false,
  }) =>
      ChatTransferDetailState(
        phase: phase ?? this.phase,
        detail: clearDetail ? null : detail ?? this.detail,
        message: clearMessage ? null : message ?? this.message,
      );
}

/// Keeps a transfer-detail request tied to the account session that created it.
/// The transfer amount remains the server's string representation throughout.
final class ChatTransferDetailController extends ChangeNotifier {
  ChatTransferDetailController({
    required this.gateway,
    required this.transferId,
    required this.viewerId,
    this.onSettled,
  }) : _epoch = gateway.sessionEpoch {
    _invalidations = gateway.sessionInvalidations.listen((_) => _end());
  }

  final ChatTransferDetailGateway gateway;
  final String transferId;
  final String viewerId;
  final VoidCallback? onSettled;
  final int _epoch;
  late final StreamSubscription<void> _invalidations;

  ChatTransferDetailState state = const ChatTransferDetailState();
  Future<void>? _operation;
  int _generation = 0;
  bool _disposed = false;
  bool _ended = false;

  bool get isAlive => _live();

  Future<void> load() async {
    final operation = _operation;
    if (operation != null) return operation;
    if (!_live()) return;
    final generation = ++_generation;
    _set(state.copyWith(
      phase: ChatTransferDetailPhase.loading,
      clearMessage: true,
    ));
    try {
      final detail = await gateway.detail(transferId);
      if (!_current(generation)) return;
      _set(ChatTransferDetailState(
        phase: ChatTransferDetailPhase.ready,
        detail: _immutableDetail(detail),
      ));
    } catch (_) {
      if (!_current(generation)) return;
      _set(state.copyWith(
        phase: ChatTransferDetailPhase.failed,
        message: '转账状态查询失败，请稍后重试',
      ));
    }
  }

  Future<void> retry() => load();

  Future<void> accept() => _perform(_TransferAction.accept);

  Future<void> decline() => _perform(_TransferAction.decline);

  Future<void> _perform(_TransferAction action) {
    final existing = _operation;
    if (existing != null) return existing;
    if (!_canAct()) return Future<void>.value();
    final operation = _performCurrent(action);
    _operation = operation;
    operation.whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
    });
    return operation;
  }

  Future<void> _performCurrent(_TransferAction action) async {
    if (!_live()) return;
    final generation = ++_generation;
    _set(state.copyWith(
      phase: ChatTransferDetailPhase.loading,
      clearMessage: true,
    ));
    try {
      final updated = await switch (action) {
        _TransferAction.accept => gateway.accept(transferId),
        _TransferAction.decline => gateway.decline(transferId),
      };
      if (!_current(generation)) return;
      _set(ChatTransferDetailState(
        phase: ChatTransferDetailPhase.ready,
        detail: _immutableDetail(updated),
      ));
      if (!_live() || generation != _generation) return;
      _notifySettled();
      await _refreshAfterSettlement(generation);
    } catch (_) {
      if (!_current(generation)) return;
      _set(state.copyWith(
        phase: ChatTransferDetailPhase.ready,
        message: '操作失败，请稍后重试',
      ));
    }
  }

  Future<void> _refreshAfterSettlement(int generation) async {
    if (!_current(generation)) return;
    try {
      final refreshed = await gateway.detail(transferId);
      if (!_current(generation)) return;
      _set(ChatTransferDetailState(
        phase: ChatTransferDetailPhase.ready,
        detail: _immutableDetail(refreshed),
      ));
    } catch (_) {
      if (!_current(generation)) return;
      _set(state.copyWith(
        phase: ChatTransferDetailPhase.ready,
        message: '详情更新失败，请稍后重试',
      ));
    }
  }

  void _notifySettled() {
    try {
      onSettled?.call();
    } catch (error, stackTrace) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'chat transfer detail controller',
        context: ErrorDescription('while notifying a settled transfer'),
      ));
    }
  }

  bool _canAct() {
    if (!_live()) return false;
    final detail = state.detail;
    return detail?['status']?.toString() == 'PENDING' &&
        detail?['receiver_id']?.toString() == viewerId;
  }

  bool _current(int generation) =>
      generation == _generation && !_disposed && !_ended && _live();

  bool _live() {
    if (_disposed || _ended) return false;
    if (gateway.sessionEpoch != _epoch) {
      _end();
      return false;
    }
    return true;
  }

  Map<String, dynamic> _immutableDetail(Map<String, dynamic> detail) =>
      Map<String, dynamic>.unmodifiable(Map<String, dynamic>.from(detail));

  void _end() {
    if (_ended) return;
    _ended = true;
    _generation++;
    _operation = null;
    state = const ChatTransferDetailState(phase: ChatTransferDetailPhase.ended);
    unawaited(_invalidations.cancel());
    if (!_disposed) notifyListeners();
  }

  void _set(ChatTransferDetailState next) {
    if (!_live()) return;
    state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _end();
    super.dispose();
  }
}

enum _TransferAction { accept, decline }
