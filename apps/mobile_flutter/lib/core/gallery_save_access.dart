import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

final class GallerySavePermissionDenied implements Exception {}

/// 只在保存操作时申请写权限；Android 10+ 通过 MediaStore 写自己的媒体。
Future<void> ensureGallerySaveAccess() async {
  Permission? required;
  if (defaultTargetPlatform == TargetPlatform.android) {
    final sdk = await const MethodChannel('chatflow/gallery')
        .invokeMethod<int>('androidSdk');
    if (sdk == null) throw StateError('Android version unavailable');
    if (sdk <= 28) required = Permission.storage;
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    required = Permission.photosAddOnly;
  }
  if (required == null) return;
  final result = await required.request();
  if (!result.isGranted && !result.isLimited) {
    throw GallerySavePermissionDenied();
  }
}

String gallerySaveErrorMessage(Object error) =>
    error is GallerySavePermissionDenied
        ? '未获得相册写入权限，请在系统设置中允许后重试'
        : '保存失败，请稍后重试';
