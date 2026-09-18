import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:photo_manager/photo_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/gallery_save_access.dart';

/// 二维码导出失败：`message` 是可直接展示给用户的可读原因（绝不静默失败）。
final class WalletQrExportException implements Exception {
  const WalletQrExportException(this.message);

  final String message;

  @override
  String toString() => 'WalletQrExportException($message)';
}

/// 收款二维码导出器（申请权限 → 渲染 PNG → 写入系统相册）。
///
/// 页面只依赖这个接口：生产用 [GalleryQrExporter]（真实申请权限 + 真实写相册），
/// 测试注入假实现以覆盖成功/失败/禁用态的可见反馈。
abstract interface class WalletQrExporter {
  /// 保存二维码；失败抛出可读异常。
  Future<void> saveQrCode(String data);
}

/// 生产实现：与聊天图片/视频保存走同一条能力链（[ensureGallerySaveAccess] +
/// `PhotoManager.editor.saveImage`），因此权限被拒时有完全一致的可读提示。
final class GalleryQrExporter implements WalletQrExporter {
  const GalleryQrExporter();

  /// 导出 PNG 边长（含白边静区），足够放大扫码。
  static const pngSize = 720.0;

  /// 静区（白边）占整幅的比例：QR 规范要求至少 4 个模块宽，取下限以上。
  static const quietZoneRatio = 0.04;

  @override
  Future<void> saveQrCode(String data) async {
    // 1) 权限：Android 9- 存储写 / iOS 仅新增照片；被拒抛 GallerySavePermissionDenied。
    await ensureGallerySaveAccess();
    // 2) 渲染：白底 + 静区，深色主题下也不会导出反色二维码。
    final bytes = await renderQrPng(data);
    // 3) 写入系统相册。
    final entity = await PhotoManager.editor.saveImage(
      bytes,
      filename:
          'changliao-wallet-qr-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    if (entity.id.isEmpty) {
      throw const WalletQrExportException('保存失败，请稍后重试');
    }
  }

  /// 把 [data] 渲染为 PNG 字节（白底 + 静区 + 纯黑模块，与主题无关）。
  static Future<Uint8List> renderQrPng(String data,
      {double size = pngSize}) async {
    if (data.isEmpty) {
      throw const WalletQrExportException('收款地址为空，无法生成二维码');
    }
    final painter = QrPainter(
      data: data,
      version: QrVersions.auto,
      gapless: true,
      eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square, color: ui.Color(0xFF000000)),
      dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: ui.Color(0xFF000000)),
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final quiet = size * quietZoneRatio;
    canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, size, size),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF));
    canvas.translate(quiet, quiet);
    painter.paint(canvas, ui.Size(size - quiet * 2, size - quiet * 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    picture.dispose();
    try {
      final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
      if (encoded == null) {
        throw const WalletQrExportException('二维码生成失败，请稍后重试');
      }
      return encoded.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}

/// 把导出异常翻译成给用户看的原因（权限被拒 → 引导去系统设置）。
String walletQrExportErrorMessage(Object error) =>
    error is WalletQrExportException
        ? error.message
        : gallerySaveErrorMessage(error);
