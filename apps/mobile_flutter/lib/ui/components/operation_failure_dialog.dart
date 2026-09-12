import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import '../../core/business_api_error.dart';

enum OperationFailureKind { network, service, other }

OperationFailureKind classifyOperationFailure(Object error) {
  if (error is HttpExceptionWithStatus) {
    if (error.statusCode == 401 ||
        error.statusCode == 403 ||
        error.statusCode == 404) {
      return OperationFailureKind.other;
    }
    if (error.statusCode >= 500) {
      return OperationFailureKind.service;
    }
    return OperationFailureKind.other;
  }
  if (error is SocketException ||
      error is TimeoutException ||
      error is HttpException ||
      error is http.ClientException) {
    return OperationFailureKind.network;
  }
  if (error is BusinessApiException && error.statusCode >= 500) {
    return OperationFailureKind.service;
  }
  return OperationFailureKind.other;
}

Future<bool> showRetryableOperationFailure(
    BuildContext context, Object error) async {
  final kind = classifyOperationFailure(error);
  if (kind == OperationFailureKind.other) return false;
  final navigator = Navigator.of(context, rootNavigator: true);
  if (_dialogs.containsKey(navigator)) return false;
  final label = kind == OperationFailureKind.network
      ? error is TimeoutException
          ? '请求超时，请检查网络后重试'
          : '网络不可用，请检查网络后重试'
      : '服务暂时不可用，请稍后重试';
  late final Future<bool> dialog;
  dialog = showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
              title: const Text('操作未完成'),
              content: Text(label),
              actions: [
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                CupertinoDialogAction(
                    isDefaultAction: true,
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('重试')),
              ])).then((value) => value ?? false).whenComplete(() {
    if (identical(_dialogs[navigator], dialog)) _dialogs.remove(navigator);
  });
  _dialogs[navigator] = dialog;
  return dialog;
}

final _dialogs = <NavigatorState, Future<bool>>{};
