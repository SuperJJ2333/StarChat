import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'matrix_e2ee_client.dart';

enum MatrixVerificationRequestPhase { incoming, revoked }

@immutable
final class MatrixVerificationRequestSnapshot {
  const MatrixVerificationRequestSnapshot({
    required this.requestId,
    required this.phase,
  });

  final String requestId;
  final MatrixVerificationRequestPhase phase;

  @override
  bool operator ==(Object other) =>
      other is MatrixVerificationRequestSnapshot &&
      other.requestId == requestId &&
      other.phase == phase;

  @override
  int get hashCode => Object.hash(requestId, phase);
}

final class _IncomingSasEvent {
  const _IncomingSasEvent(this.generation, this.handle);
  final int generation;
  final MatrixSasRequestHandle handle;
}

/// UI-facing SAS state. SDK handles, SAS values and identities never leave
/// this service.
final class MatrixVerificationService {
  MatrixVerificationService(
    this.matrix, {
    Stream<MatrixSasRequestHandle> Function()? incomingRequests,
    String Function()? requestIdFactory,
  })  : _incomingRequests = incomingRequests,
        _requestIdFactory = requestIdFactory ?? _newOpaqueRequestId;

  final MatrixSdkE2eeClient matrix;
  final Stream<MatrixSasRequestHandle> Function()? _incomingRequests;
  final String Function() _requestIdFactory;
  final Map<String, MatrixSasRequestHandle> _requests = {};
  final List<MatrixSasRequestHandle> _revokedRequests = [];
  final Set<String> _issuedRequestIds = {};
  MatrixManagedSubscription? _subscription;
  MatrixManagedResource? _lifecycleResource;
  Future<void>? _lifecycleSetup;
  Future<void>? _listenSetup;
  Future<void> _requestTail = Future<void>.value();
  bool _disposed = false;
  void Function(MatrixVerificationRequestSnapshot state)? _onState;
  int _generation = 0;
  bool _lifecycleRevoked = false;

  Future<void> _ensureLifecycle() => _lifecycleSetup ??= () async {
        final resource = await matrix.registerVerificationLifecycle(
          open: () async => _lifecycleRevoked = false,
          revoke: _revokeForLifecycleTransition,
          close: _closeRequests,
        );
        if (_disposed) {
          await resource.cancel();
          return;
        }
        _lifecycleResource = resource;
      }();

  Future<MatrixVerificationRequestSnapshot> start(
    String userId, {
    String? deviceId,
  }) async {
    await _ensureLifecycle();
    late MatrixVerificationRequestSnapshot snapshot;
    await matrix.startSasRequest(
      userId,
      deviceId: deviceId,
      onStarted: (handle) {
        final requestId = _nextRequestId();
        _requests[requestId] = handle;
        snapshot = MatrixVerificationRequestSnapshot(
          requestId: requestId,
          phase: MatrixVerificationRequestPhase.incoming,
        );
        _emitState(snapshot);
      },
    );
    return snapshot;
  }

  Future<void> listenForIncoming(
    void Function(MatrixVerificationRequestSnapshot state) onState,
  ) {
    if (_disposed) {
      return Future<void>.error(
        StateError('Matrix verification service is disposed'),
      );
    }
    return _listenSetup = _listenForIncoming(onState);
  }

  Future<void> _listenForIncoming(
    void Function(MatrixVerificationRequestSnapshot state) onState,
  ) async {
    await _ensureLifecycle();
    if (_disposed) return;
    _onState = onState;
    await _subscription?.cancel();
    final sourceGeneration = _generation;
    final subscription = await matrix.subscribeSasRequests(
      testSource: _incomingRequests,
      onData: (handle) => unawaited(
        _adoptIncoming(_IncomingSasEvent(sourceGeneration, handle)),
      ),
    );
    if (_disposed) {
      await subscription.cancel();
      return;
    }
    _subscription = subscription;
  }

  Future<void> accept(String requestId) =>
      _withRequest(requestId, (request) => request.accept());
  Future<void> chooseSas(String requestId) =>
      _withRequest(requestId, (request) => request.continueSas());
  Future<void> confirmSas(String requestId) =>
      _withRequest(requestId, (request) => request.confirmSas());
  Future<void> reject(String requestId) =>
      _withRequest(requestId, (request) => request.reject());

  Future<void> _adoptIncoming(_IncomingSasEvent event) async {
    if (event.generation != _generation) {
      event.handle.dispose();
      return;
    }
    try {
      await _serializeRequests(() async {
        if (event.generation != _generation) {
          event.handle.dispose();
          return;
        }
        _revokeActiveRequests();
        _disposeRevokedRequests();
        late final String requestId;
        try {
          requestId = _nextRequestId();
        } catch (_) {
          event.handle.dispose();
          return;
        }
        _requests[requestId] = event.handle;
        _emitState(MatrixVerificationRequestSnapshot(
          requestId: requestId,
          phase: MatrixVerificationRequestPhase.incoming,
        ));
      });
    } catch (_) {
      event.handle.dispose();
    }
  }

  Future<void> _withRequest(
    String requestId,
    Future<void> Function(MatrixSasRequestHandle request) action,
  ) async {
    await _ensureLifecycle();
    if (!_requests.containsKey(requestId)) {
      throw StateError('Matrix verification request is unavailable');
    }
    await _serializeRequests(() async {
      final request = _requests[requestId];
      if (request == null) {
        throw StateError('Matrix verification request is unavailable');
      }
      await action(request);
    });
  }

  Future<T> _serializeRequests<T>(Future<T> Function() operation) {
    final result = _requestTail.then<T>((_) => operation());
    _requestTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _closeRequests() async {
    _revokeForLifecycleTransition();
    await _requestTail;
    _disposeRevokedRequests();
  }

  void _revokeForLifecycleTransition() {
    if (_lifecycleRevoked) return;
    _lifecycleRevoked = true;
    _generation++;
    _revokeActiveRequests();
  }

  void _revokeActiveRequests() {
    final revokedIds = _requests.keys.toList(growable: false);
    _revokedRequests.addAll(_requests.values);
    _requests.clear();
    for (final requestId in revokedIds) {
      _emitState(MatrixVerificationRequestSnapshot(
        requestId: requestId,
        phase: MatrixVerificationRequestPhase.revoked,
      ));
    }
  }

  void _disposeRevokedRequests() {
    for (final request in _revokedRequests) {
      request.dispose();
    }
    _revokedRequests.clear();
  }

  void _emitState(MatrixVerificationRequestSnapshot state) {
    try {
      _onState?.call(state);
    } catch (_) {
      debugPrint('E2EE_VERIFICATION_STATE_CALLBACK_FAILED');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _listenSetup;
    } catch (_) {}
    try {
      await _lifecycleSetup;
    } catch (_) {}
    await _subscription?.cancel();
    _subscription = null;
    await _lifecycleResource?.cancel();
    _lifecycleResource = null;
    _onState = null;
    _revokeActiveRequests();
    _disposeRevokedRequests();
  }

  String _nextRequestId() {
    final requestId = _requestIdFactory();
    if (requestId.isEmpty || requestId != requestId.trim()) {
      throw StateError('Matrix verification request id is invalid');
    }
    if (_issuedRequestIds.contains(requestId)) {
      throw StateError('Matrix verification request id collision');
    }
    _issuedRequestIds.add(requestId);
    return requestId;
  }

  static String _newOpaqueRequestId() => base64UrlEncode(
        List<int>.generate(18, (_) => Random.secure().nextInt(256)),
      );
}
