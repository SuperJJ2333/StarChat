import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/gallery_save_access.dart';
import '../components/wechat_scaffold.dart';
import '../foundation/wechat_tokens.dart';
import 'image_crop_geometry.dart';

enum ImageEditTool { brush, emoji, text, crop, mosaic, eraser }

const _editorEmojis = [
  '😀',
  '😄',
  '😂',
  '🥹',
  '😍',
  '🥰',
  '😎',
  '😭',
  '😡',
  '🤔',
  '🤗',
  '😘',
  '🥳',
  '🤩',
  '👍',
  '👎',
  '👏',
  '🙏',
  '💪',
  '🤝',
  '✌️',
  '❤️',
  '💛',
  '💚',
  '💙',
  '🔥',
  '🎉',
  '🌹',
  '🐱',
  '🐶',
  '🌈',
  '☀️',
  '⭐',
  '🎂',
  '🎁',
];

/// 裁剪框最小可应用边长（图像像素）：再小的裁剪没有意义。
const double minCropImagePixels = 16;

/// 裁剪比例预设：`自由` 之外都是固定宽高比（宽/高）。
const _cropAspects = <({String id, String label, double? aspect})>[
  (id: 'free', label: '自由', aspect: null),
  (id: '1-1', label: '1:1', aspect: 1),
  (id: '4-5', label: '4:5', aspect: 4 / 5),
  (id: '16-9', label: '16:9', aspect: 16 / 9),
];

/// All coordinates are in decoded image pixels, independent of viewport/crop.
@immutable
class ImageEditMark {
  const ImageEditMark(
      {required this.points,
      required this.color,
      required this.width,
      this.text,
      this.mosaic = false,
      this.eraser = false});
  final List<Offset> points;
  final Color color;
  final double width;
  final String? text;
  final bool mosaic;
  final bool eraser;
  ImageEditMark moved(Offset delta) => ImageEditMark(
      points: points.map((point) => point + delta).toList(),
      color: color,
      width: width,
      text: text,
      mosaic: mosaic,
      eraser: eraser);
}

/// 编辑文档：**已旋转的文档空间**中的裁剪区域与标注。
///
/// [rotation] 是顺时针 90° 的整数倍。旋转时 [crop] 与 [marks] 一起被
/// 映射到新的文档空间——因此旋转后标注仍贴在原图的同一处。
@immutable
class ImageEditDocument {
  const ImageEditDocument(this.crop, this.marks, {this.rotation = 0});
  final Rect crop;
  final List<ImageEditMark> marks;
  final int rotation;
}

/// 图片文档空间尺寸（旋转 90°/270° 时宽高互换）。
Size documentSpaceSize(ui.Image image, int rotation) => rotation.isEven
    ? Size(image.width.toDouble(), image.height.toDouble())
    : Size(image.height.toDouble(), image.width.toDouble());

/// 把画布旋转到「图像像素 → 文档空间」的映射。
void applyImageRotation(Canvas canvas, ui.Image image, int rotation) {
  final width = image.width.toDouble();
  final height = image.height.toDouble();
  switch (rotation & 3) {
    case 1:
      canvas.translate(height, 0);
      canvas.rotate(math.pi / 2);
      break;
    case 2:
      canvas.translate(width, height);
      canvas.rotate(math.pi);
      break;
    case 3:
      canvas.translate(0, width);
      canvas.rotate(3 * math.pi / 2);
      break;
  }
}

/// 顺时针旋转 90°：裁剪区域与标注一起映射到新的文档空间。
ImageEditDocument rotatedDocument(ImageEditDocument document, ui.Image image) {
  final current = documentSpaceSize(image, document.rotation);
  final crop = document.crop;
  Offset turn(Offset point) => Offset(current.height - point.dy, point.dx);
  final marks = [
    for (final mark in document.marks)
      ImageEditMark(
        points: mark.points.map(turn).toList(),
        color: mark.color,
        width: mark.width,
        text: mark.text,
        mosaic: mark.mosaic,
        eraser: mark.eraser,
      )
  ];
  return ImageEditDocument(
    Rect.fromLTRB(current.height - crop.bottom, crop.left,
        current.height - crop.top, crop.right),
    marks,
    rotation: (document.rotation + 1) % 4,
  );
}

/// 在文档空间绘制「旋转后的原图 + 标注」；导出与屏幕渲染共用同一实现，
/// 保证「所见即所得」。
void paintImageDocument(
    Canvas canvas, ui.Image image, ui.Image mosaic, ImageEditDocument document) {
  final bounds = Offset.zero & documentSpaceSize(image, document.rotation);
  canvas.save();
  applyImageRotation(canvas, image, document.rotation);
  canvas.drawImage(image, Offset.zero, Paint());
  canvas.restore();
  // 标注单独成层：橡皮擦的 BlendMode.clear 只擦标注，不会擦穿原图。
  canvas.saveLayer(document.crop, Paint());
  for (final mark in document.marks) {
    if (mark.text != null) {
      final painter = TextPainter(
          text: TextSpan(
              text: mark.text,
              style: TextStyle(
                  color: mark.color,
                  fontSize: mark.width,
                  shadows: const [
                    Shadow(color: CupertinoColors.black, blurRadius: 2)
                  ])),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center)
        ..layout(maxWidth: bounds.width);
      painter.paint(canvas,
          mark.points.first - Offset(painter.width / 2, painter.height / 2));
      painter.dispose();
    } else if (mark.mosaic) {
      final path = Path();
      for (var i = 0; i < mark.points.length; i++) {
        final point = mark.points[i];
        path.addOval(Rect.fromCircle(center: point, radius: mark.width * 2));
        if (i > 0) {
          final previous = mark.points[i - 1];
          final delta = point - previous;
          final steps =
              (delta.distance / (mark.width == 0 ? 1 : mark.width)).ceil();
          for (var step = 1; step < steps; step++) {
            path.addOval(Rect.fromCircle(
                center: previous + delta * (step / steps),
                radius: mark.width * 2));
          }
        }
      }
      canvas.save();
      canvas.clipPath(path);
      canvas.save();
      applyImageRotation(canvas, image, document.rotation);
      canvas.drawImageRect(
          mosaic,
          Rect.fromLTWH(
              0, 0, mosaic.width.toDouble(), mosaic.height.toDouble()),
          Rect.fromLTWH(
              0, 0, image.width.toDouble(), image.height.toDouble()),
          Paint()..filterQuality = FilterQuality.none);
      canvas.restore();
      canvas.restore();
    } else if (mark.points.isNotEmpty) {
      final paint = Paint()
        ..color = mark.color
        ..strokeWidth = mark.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..blendMode = mark.eraser ? BlendMode.clear : BlendMode.srcOver;
      if (mark.points.length == 1) {
        canvas.drawCircle(
            mark.points.first,
            mark.width / 2,
            Paint()
              ..color = mark.color
              ..blendMode =
                  mark.eraser ? BlendMode.clear : BlendMode.srcOver);
      } else {
        final path = Path()
          ..moveTo(mark.points.first.dx, mark.points.first.dy);
        for (final point in mark.points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
  }
  canvas.restore();
}

/// 微信级图片编辑器：画笔 / 表情 / 文字 / 裁剪 / 马赛克 / 橡皮擦。
///
/// **安全不变量**：编辑始终发生在内存中的**临时缓冲**里，导出产生新的
/// 图片字节；设备上的原图与消息里的原媒体对象永不被覆盖。取消（返回）
/// 不产生任何持久副作用。
final class WeChatImageEditorPage extends StatefulWidget {
  const WeChatImageEditorPage(
      {super.key,
      required this.bytes,
      this.onForward,
      this.onFavorite,
      this.onSend});
  final Uint8List bytes;
  final Future<bool> Function(Future<Uint8List> Function() export)?
      onForward;
  final Future<void> Function(Uint8List)? onFavorite;

  /// 「发送」动作：把编辑结果作为**新的媒体对象**交给上层（相册预览 →
  /// 发送编辑后的图片）。返回 true 时编辑页以结果字节关闭。
  final Future<bool> Function(Uint8List bytes)? onSend;
  @override
  State<WeChatImageEditorPage> createState() => _WeChatImageEditorPageState();
}

class _WeChatImageEditorPageState extends State<WeChatImageEditorPage> {
  ui.Image? _image, _mosaic;
  final _history = <ImageEditDocument>[];
  int _cursor = -1;
  ImageEditTool _tool = ImageEditTool.brush;
  Color _color = CupertinoColors.white;
  double _width = 8;
  List<Offset> _stroke = [];
  Offset? _last;
  int? _movingMark;
  List<ImageEditMark>? _movingMarks;
  bool _busy = false;
  String? _error;
  ImageEditDocument get _doc => _history[_cursor];
  double get _strokeWidth => _image!.width / 350 * _width;

  // —— 裁剪会话（只在 [ImageEditTool.crop] 生效）——
  //
  // 约定：裁剪框 [_cropFrame] 与图片适配矩形 [_cropBounds] 都在**画布
  // 坐标**里；[_viewScale]/[_viewOffset] 描述用户对图片的缩放与拖动。
  // 裁剪框默认覆盖整张图片（= [_cropBounds]），不是固定小框。
  Rect? _cropFrame;
  Rect? _cropBounds;
  double? _cropAspect;
  double _viewScale = 1;
  Offset _viewOffset = Offset.zero;
  CropHandle _activeHandle = CropHandle.none;
  Rect? _gestureFrame;
  double _gestureScale = 1;
  Offset _gestureOffset = Offset.zero;
  Offset _gestureFocal = Offset.zero;
  Size _canvasSize = Size.zero;

  bool get _cropping => _tool == ImageEditTool.crop;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    ui.Codec? codec, smallCodec;
    ui.ImmutableBuffer? descriptor;
    ui.ImageDescriptor? info;
    ui.Image? decodedImage, decodedMosaic;
    try {
      // Bound working memory for camera panoramas while retaining useful output.
      descriptor = await ui.ImmutableBuffer.fromUint8List(widget.bytes);
      info = await ui.ImageDescriptor.encoded(descriptor);
      final scale =
          4096 / (info.width > info.height ? info.width : info.height);
      codec = await info.instantiateCodec(
          targetWidth: scale < 1
              ? (info.width * scale).round().clamp(1, 4096)
              : info.width,
          targetHeight: scale < 1
              ? (info.height * scale).round().clamp(1, 4096)
              : info.height);
      final image = decodedImage = (await codec.getNextFrame()).image;
      smallCodec = await ui.instantiateImageCodec(widget.bytes,
          targetWidth: (image.width / 20).ceil().clamp(1, 256),
          targetHeight: (image.height / 20).ceil().clamp(1, 256));
      final mosaic = decodedMosaic = (await smallCodec.getNextFrame()).image;
      if (!mounted) return;
      setState(() {
        _image = image;
        _mosaic = mosaic;
        _history.add(ImageEditDocument(
            Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            const []));
        _cursor = 0;
      });
      decodedImage = decodedMosaic = null; // Ownership transferred to State.
    } catch (_) {
      if (mounted) setState(() => _error = '图片打开失败，请返回重试');
    } finally {
      decodedImage?.dispose();
      decodedMosaic?.dispose();
      codec?.dispose();
      smallCodec?.dispose();
      info?.dispose();
      descriptor?.dispose();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    _mosaic?.dispose();
    super.dispose();
  }

  ImageEditDocument _documentWith({Rect? crop, List<ImageEditMark>? marks}) =>
      ImageEditDocument(crop ?? _doc.crop, marks ?? _doc.marks,
          rotation: _doc.rotation);

  /// 提交一个新文档（撤销栈尾部截断）。任何裁剪会话状态都被丢弃——
  /// 裁剪框会回到「覆盖整张图片」的默认态。
  void _commit(ImageEditDocument next) {
    setState(() {
      _history.removeRange(_cursor + 1, _history.length);
      _history.add(next);
      _cursor++;
      _stroke = [];
      _movingMarks = null;
      _resetCropSession();
    });
  }

  void _resetCropSession() {
    _cropFrame = null;
    _cropAspect = null;
    _viewScale = 1;
    _viewOffset = Offset.zero;
    _activeHandle = CropHandle.none;
    _gestureFrame = null;
    _movingMark = null;
    _last = null;
  }

  /// 还原：回到**原始图片**状态（默认裁剪框 / 默认缩放 / 默认旋转 /
  /// 清空全部标注），与「应用裁剪」同级同风格。
  void _restore() {
    final image = _image;
    if (image == null || _busy) return;
    setState(() {
      _history
        ..clear()
        ..add(ImageEditDocument(
            Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            const []));
      _cursor = 0;
      _stroke = [];
      _movingMarks = null;
      _resetCropSession();
      _error = null;
    });
  }

  void _rotate() {
    final image = _image;
    if (image == null || _busy) return;
    setState(() {
      _history.removeRange(_cursor + 1, _history.length);
      _history.add(rotatedDocument(_doc, image));
      _cursor++;
      _stroke = [];
      _movingMarks = null;
      _cropFrame = null;
      _viewScale = 1;
      _viewOffset = Offset.zero;
      _activeHandle = CropHandle.none;
      _gestureFrame = null;
    });
  }

  Future<void> _addText({bool emoji = false}) async {
    String? value;
    if (emoji) {
      value = await showCupertinoModalPopup<String>(
          context: context,
          builder: (context) => Container(
              height: WeChatDimensions.controlHeight * 6 + WeChatSpacing.sm * 4,
              color: CupertinoColors.systemBackground.resolveFrom(context),
              child: SafeArea(
                  top: false,
                  child: LayoutBuilder(builder: (context, constraints) {
                    const cellSize = WeChatDimensions.controlHeight;
                    const gap = WeChatSpacing.sm;
                    final columns =
                        ((constraints.maxWidth - WeChatSpacing.xxl + gap) /
                                (cellSize + gap))
                            .floor()
                            .clamp(1, 6);
                    final gridWidth = columns * cellSize + (columns - 1) * gap;
                    return Center(
                        child: SizedBox(
                            width: gridWidth,
                            child: GridView.builder(
                                key: const Key('image-editor-emoji-grid'),
                                padding: const EdgeInsets.symmetric(
                                    vertical: WeChatSpacing.md),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: columns,
                                        mainAxisSpacing: gap,
                                        crossAxisSpacing: gap),
                                itemCount: _editorEmojis.length,
                                itemBuilder: (context, index) {
                                  final item = _editorEmojis[index];
                                  return CupertinoButton(
                                      key: ValueKey(
                                          'image-editor-emoji-cell-$item'),
                                      padding: EdgeInsets.zero,
                                      minimumSize:
                                          const Size(cellSize, cellSize),
                                      onPressed: () =>
                                          Navigator.pop(context, item),
                                      child: Text(item,
                                          textScaler: TextScaler.noScaling,
                                          style: const TextStyle(
                                              fontSize:
                                                  WeChatTypography.display)));
                                })));
                  }))));
    } else {
      final input = TextEditingController();
      value = await showCupertinoDialog<String>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
                  title: const Text('添加文字'),
                  content: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: CupertinoTextField(
                          controller: input,
                          autofocus: true,
                          maxLength: 200,
                          maxLines: 4,
                          placeholder: '输入文字')),
                  actions: [
                    CupertinoDialogAction(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    CupertinoDialogAction(
                        onPressed: () => Navigator.pop(context, input.text),
                        child: const Text('添加'))
                  ]));
      // Dialog removal animates; its text field may still reference the controller.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      input.dispose();
    }
    if (!mounted || value == null || value.trim().isEmpty) return;
    _commit(_documentWith(marks: [
      ..._doc.marks,
      ImageEditMark(
          points: [_doc.crop.center],
          color: _color,
          width: _doc.crop.width / (emoji ? 7 : 14),
          text: value.trim())
    ]));
  }

  void _selectTool(ImageEditTool tool) {
    setState(() {
      _tool = tool;
      if (tool == ImageEditTool.crop) {
        // 进入裁剪：图片完整铺满编辑区域，裁剪框默认覆盖整张图片。
        _cropFrame = null;
        _cropAspect = null;
        _viewScale = 1;
        _viewOffset = Offset.zero;
        _activeHandle = CropHandle.none;
      } else {
        _resetCropSession();
      }
    });
    if (tool == ImageEditTool.emoji || tool == ImageEditTool.text) {
      _addText(emoji: tool == ImageEditTool.emoji);
    }
  }

  // —— 视图 / 图像坐标映射 ——

  /// 图片按 contain 适配到画布后的矩形（不含用户缩放与拖动）。
  Rect _fittedBounds(Size canvas) {
    final size = _doc.crop.size;
    if (canvas.isEmpty || size.isEmpty) return Rect.zero;
    final fitted = applyBoxFit(BoxFit.contain, size, canvas).destination;
    return Alignment.center.inscribe(fitted, Offset.zero & canvas);
  }

  /// 图片当前在画布上的矩形（含缩放与拖动）。
  Rect _imageViewRect() {
    final bounds = _cropBounds ?? _fittedBounds(_canvasSize);
    if (bounds.isEmpty || _doc.crop.width <= 0) return bounds;
    final scale = bounds.width / _doc.crop.width * _viewScale;
    return Rect.fromCenter(
        center: bounds.center + _viewOffset,
        width: _doc.crop.width * scale,
        height: _doc.crop.height * scale);
  }

  /// 画布坐标 → 图像像素（夹在文档空间内）。
  Offset _toImage(Offset local) {
    final rect = _imageViewRect();
    if (rect.width <= 0 || rect.height <= 0) return _doc.crop.center;
    return Offset(
      (_doc.crop.left +
              (local.dx - rect.left) / rect.width * _doc.crop.width)
          .clamp(_doc.crop.left, _doc.crop.right),
      (_doc.crop.top +
              (local.dy - rect.top) / rect.height * _doc.crop.height)
          .clamp(_doc.crop.top, _doc.crop.bottom),
    );
  }

  /// 夹取图片中心，保证图片始终盖住适配矩形（裁剪框所在的区域）。
  Offset _clampCenter(Offset center, Rect bounds, double scale) {
    final halfWidth = _doc.crop.width * scale / 2;
    final halfHeight = _doc.crop.height * scale / 2;
    final minX = bounds.right - halfWidth;
    final maxX = bounds.left + halfWidth;
    final minY = bounds.bottom - halfHeight;
    final maxY = bounds.top + halfHeight;
    return Offset(
      center.dx.clamp(math.min(minX, maxX), math.max(minX, maxX)),
      center.dy.clamp(math.min(minY, maxY), math.max(minY, maxY)),
    );
  }

  void _panStart(Offset local) {
    final point = _toImage(local);
    _last = point;
    if (_tool == ImageEditTool.text || _tool == ImageEditTool.emoji) {
      // Text/emoji remain movable after adding, without creating another layer.
      for (var i = _doc.marks.length - 1; i >= 0; i--) {
        final mark = _doc.marks[i];
        if (mark.text != null &&
            (mark.points.first - point).distance < mark.width * 4) {
          _movingMark = i;
          _movingMarks = [..._doc.marks];
          break;
        }
      }
    } else {
      setState(() => _stroke = [point]);
    }
  }

  void _panUpdate(Offset local) {
    final point = _toImage(local);
    setState(() {
      if (_movingMark != null) {
        final index = _movingMark!;
        _movingMarks![index] = _movingMarks![index].moved(point - _last!);
      } else if (_stroke.isNotEmpty) {
        _stroke = [..._stroke, point];
      }
      _last = point;
    });
  }

  void _panEnd() {
    if (_movingMarks != null) {
      _commit(_documentWith(marks: _movingMarks!));
      return;
    }
    if (_stroke.isNotEmpty) {
      _commit(_documentWith(marks: [
        ..._doc.marks,
        ImageEditMark(
            points: List.of(_stroke),
            color: _color,
            width: _strokeWidth,
            mosaic: _tool == ImageEditTool.mosaic,
            eraser: _tool == ImageEditTool.eraser)
      ]));
      return;
    }
    _movingMark = null;
    _last = null;
  }

  // —— 裁剪手势：拖动四边/四角调整裁剪框；拖动/捏合图片 ———

  bool get _canApplyCrop {
    final frame = _cropFrame;
    final bounds = _cropBounds;
    if (frame == null || bounds == null) return false;
    final imageRect = ImageCropGeometry.toImageRect(
        frame: frame, imageViewRect: bounds, imageBounds: _doc.crop);
    return imageRect.width >= minCropImagePixels &&
        imageRect.height >= minCropImagePixels;
  }

  void _cropStart(ScaleStartDetails details) {
    final frame = _cropFrame;
    final bounds = _cropBounds;
    if (frame == null || bounds == null) return;
    _gestureFocal = details.localFocalPoint;
    _gestureScale = _viewScale;
    _gestureOffset = _viewOffset;
    _gestureFrame = frame;
    // 单指落在边框/控制点上 = 调整裁剪范围；否则 = 移动/缩放图片。
    _activeHandle = details.pointerCount == 1
        ? ImageCropGeometry.handleAt(frame, details.localFocalPoint)
        : CropHandle.none;
  }

  void _cropUpdate(ScaleUpdateDetails details) {
    final startFrame = _gestureFrame;
    final bounds = _cropBounds;
    if (startFrame == null || bounds == null) return;
    if (_activeHandle != CropHandle.none && details.pointerCount == 1) {
      final next = ImageCropGeometry.resize(
        frame: startFrame,
        handle: _activeHandle,
        delta: details.localFocalPoint - _gestureFocal,
        bounds: bounds,
        aspect: _cropAspect,
      );
      setState(() => _cropFrame = next);
      return;
    }
    final baseScale = bounds.width / _doc.crop.width;
    final nextScale = (_gestureScale * details.scale).clamp(1.0, 8.0);
    final ratio = nextScale / _gestureScale;
    final origin = bounds.center + _gestureOffset;
    // 以手势起点的焦点为锚：焦点下的图像点保持不动；单指拖动时
    // ratio == 1，退化成画面跟手平移。
    final nextOrigin =
        details.localFocalPoint - (_gestureFocal - origin) * ratio;
    final center = _clampCenter(nextOrigin, bounds, baseScale * nextScale);
    setState(() {
      _activeHandle = CropHandle.none;
      _viewScale = nextScale;
      _viewOffset = center - bounds.center;
    });
  }

  void _cropEnd() {
    // 松手后必须清掉高亮并重建，否则控制点会一直停在激活色上。
    setState(() {
      _activeHandle = CropHandle.none;
      _gestureFrame = _cropFrame;
      _gestureOffset = _viewOffset;
      _gestureScale = _viewScale;
    });
  }

  void _applyCrop() {
    final frame = _cropFrame;
    final bounds = _cropBounds;
    if (frame == null || bounds == null || _busy) return;
    if (!_canApplyCrop) return;
    // 裁剪框（视图）→ 图像像素，产生**新文档**；原图字节不被修改。
    _commit(_documentWith(
        crop: ImageCropGeometry.toImageRect(
            frame: frame, imageViewRect: bounds, imageBounds: _doc.crop)));
  }

  Future<Uint8List> _export() async {
    final image = _image!;
    final document = _doc;
    final width = document.crop.width.round().clamp(1, 4096);
    final height = document.crop.height.round().clamp(1, 4096);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(width / document.crop.width, height / document.crop.height);
    canvas.translate(-document.crop.left, -document.crop.top);
    paintImageDocument(canvas, image, _mosaic!, document);
    final picture = recorder.endRecording();
    late ui.Image rendered;
    try {
      rendered = await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
    try {
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Image encoding failed');
      return data.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  }

  Future<void> _finish() async {
    if (_busy || _image == null) return;
    final action = await showCupertinoModalPopup<String>(
        context: context,
        builder: (context) => CupertinoActionSheet(
                actions: [
                  if (widget.onSend != null)
                    CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(context, 'send'),
                        child: const Text('发送')),
                  if (widget.onForward != null)
                    CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(context, 'forward'),
                        child: const Text('转发')),
                  CupertinoActionSheetAction(
                      onPressed: () => Navigator.pop(context, 'save'),
                      child: const Text('保存到本地')),
                  if (widget.onFavorite != null)
                    CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(context, 'favorite'),
                        child: const Text('收藏')),
                ],
                cancelButton: CupertinoActionSheetAction(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'))));
    if (!mounted || action == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var done = true;
    try {
      // 转发先开选择器、确认后再导出 PNG（大图编码数秒不再阻塞在
      // 选择器之前）；发送/保存/收藏仍需先拿到字节。
      if (action == 'forward') {
        done = await widget.onForward!(_export);
      } else {
        final bytes = await _export();
        if (!mounted) return;
        if (action == 'send') {
          done = await widget.onSend!(bytes);
          if (mounted && done) {
            Navigator.pop(context, bytes);
            return;
          }
        } else if (action == 'favorite') {
          await widget.onFavorite!(bytes);
        } else {
          await ensureGallerySaveAccess();
          final saved = await PhotoManager.editor.saveImage(bytes,
              filename:
                  'ChatFlow-edited-${DateTime.now().millisecondsSinceEpoch}.png');
          if (saved.id.isEmpty) throw StateError('Save failed');
        }
      }
      if (mounted && done) {
        setState(() => _error = switch (action) {
              'forward' => '正在发送',
              'favorite' => '已收藏',
              _ => '已保存到相册',
            });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = action == 'save'
            ? gallerySaveErrorMessage(error)
            : '操作失败，请重试，编辑内容已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      backgroundColor: CupertinoColors.black,
      navigationBar: CupertinoNavigationBar(
          backgroundColor: CupertinoColors.black,
          transitionBetweenRoutes: false,
          leading: CupertinoButton(
              key: const Key('image-editor-cancel'),
              padding: EdgeInsets.zero,
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('取消')),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            CupertinoButton(
                key: const Key('image-editor-undo'),
                padding: EdgeInsets.zero,
                onPressed: !_busy && _cursor > 0
                    ? () => setState(() {
                          _cursor--;
                          _resetCropSession();
                        })
                    : null,
                child: const Icon(CupertinoIcons.arrow_uturn_left,
                    semanticLabel: '撤销')),
            CupertinoButton(
                key: const Key('image-editor-redo'),
                padding: EdgeInsets.zero,
                onPressed: !_busy && _cursor < _history.length - 1
                    ? () => setState(() {
                          _cursor++;
                          _resetCropSession();
                        })
                    : null,
                child: const Icon(CupertinoIcons.arrow_uturn_right,
                    semanticLabel: '重做')),
          ])),
      child: SafeArea(
          child: Column(children: [
        Expanded(
            child: _image == null
                ? Center(
                    child: _error == null
                        ? const CupertinoActivityIndicator()
                        : Text(_error!,
                            style:
                                const TextStyle(color: CupertinoColors.white)))
                : LayoutBuilder(builder: (context, constraints) {
                    final canvas = constraints.biggest;
                    _canvasSize = canvas;
                    if (_cropping) {
                      // 裁剪框默认覆盖整张图片；布局/文档变化后回到该默认态。
                      final bounds = _fittedBounds(canvas);
                      _cropBounds = bounds;
                      final frame = _cropFrame;
                      if (frame == null ||
                          !ImageCropGeometry.withinBounds(frame, bounds)) {
                        _cropFrame = bounds;
                      }
                    }
                    final document = ImageEditDocument(_doc.crop, [
                      ...(_movingMarks ?? _doc.marks),
                      if (_stroke.isNotEmpty)
                        ImageEditMark(
                            points: _stroke,
                            color: _color,
                            width: _strokeWidth,
                            mosaic: _tool == ImageEditTool.mosaic,
                            eraser: _tool == ImageEditTool.eraser)
                    ], rotation: _doc.rotation);
                    return SizedBox(
                        width: canvas.width,
                        height: canvas.height,
                        child: IgnorePointer(
                            ignoring: _busy,
                            child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanStart: _cropping
                                    ? null
                                    : (d) => _panStart(d.localPosition),
                                onPanUpdate: _cropping
                                    ? null
                                    : (d) => _panUpdate(d.localPosition),
                                onPanEnd: _cropping ? null : (_) => _panEnd(),
                                onPanCancel: _cropping
                                    ? null
                                    : () => setState(() {
                                          _stroke = [];
                                          _movingMarks = null;
                                          _movingMark = null;
                                        }),
                                onScaleStart: _cropping ? _cropStart : null,
                                onScaleUpdate: _cropping ? _cropUpdate : null,
                                onScaleEnd: _cropping ? (_) => _cropEnd() : null,
                                child: CustomPaint(
                                    size: canvas,
                                    painter: ImageEditorPainter(
                                        _image!, _mosaic!, document,
                                        canvasSize: canvas,
                                        selection: _cropping
                                            ? _cropFrame
                                            : null,
                                        viewScale: _viewScale,
                                        viewOffset: _viewOffset,
                                        activeHandle: _activeHandle)))));
                  })),
        if (_error != null && _image != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!,
                  style: const TextStyle(color: CupertinoColors.white))),
        if (_image != null) ...[
          if (_cropping)
            _cropOptions()
          else if (_tool == ImageEditTool.brush ||
              _tool == ImageEditTool.mosaic)
            Row(children: [
              for (final color in [
                CupertinoColors.white,
                CupertinoColors.black,
                CupertinoColors.systemRed,
                CupertinoColors.systemYellow,
                WeChatColors.brandPrimary
              ])
                CupertinoButton(
                    padding: const EdgeInsets.all(6),
                    onPressed:
                        _busy ? null : () => setState(() => _color = color),
                    child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: _color == color
                                    ? WeChatColors.brandPrimary
                                    : CupertinoColors.systemGrey,
                                width: _color == color ? 3 : 1)))),
              Expanded(
                  child: CupertinoSlider(
                      value: _width,
                      min: 2,
                      max: 28,
                      onChanged:
                          _busy ? null : (v) => setState(() => _width = v)))
            ])
          else if (_tool == ImageEditTool.eraser)
            Column(mainAxisSize: MainAxisSize.min, children: [
              const Padding(
                  padding: EdgeInsets.symmetric(horizontal: WeChatSpacing.sm),
                  child: Text('轻触或拖动擦除编辑痕迹',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: CupertinoColors.white))),
              CupertinoSlider(
                  value: _width,
                  min: 2,
                  max: 28,
                  onChanged: _busy ? null : (v) => setState(() => _width = v))
            ])
          else
            const Padding(
                padding: EdgeInsets.all(8),
                child: Text('拖动文字或表情调整位置',
                    style: TextStyle(color: CupertinoColors.white))),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            for (final entry in const [
              (ImageEditTool.brush, CupertinoIcons.pencil, '画笔'),
              (ImageEditTool.emoji, CupertinoIcons.smiley, '表情'),
              (ImageEditTool.text, CupertinoIcons.textformat, '文字'),
              (ImageEditTool.crop, CupertinoIcons.crop, '裁剪'),
              (ImageEditTool.mosaic, CupertinoIcons.square_grid_3x2, '马赛克'),
              (ImageEditTool.eraser, null, '橡皮擦')
            ])
              CupertinoButton(
                  key: ValueKey('image-editor-${entry.$1.name}'),
                  padding: const EdgeInsets.all(WeChatSpacing.sm),
                  onPressed: _busy ? null : () => _selectTool(entry.$1),
                  child: entry.$1 == ImageEditTool.eraser
                      ? _ImageEditorEraserIcon(
                          semanticLabel: entry.$3,
                          color: _tool == entry.$1
                              ? WeChatColors.brandPrimary
                              : CupertinoColors.white)
                      : Icon(entry.$2,
                          semanticLabel: entry.$3,
                          color: _tool == entry.$1
                              ? WeChatColors.brandPrimary
                              : CupertinoColors.white)),
          ]),
          if (_cropping)
            Padding(
                padding: const EdgeInsets.fromLTRB(WeChatSpacing.lg,
                    WeChatSpacing.xs, WeChatSpacing.lg, WeChatSpacing.sm),
                child: Row(children: [
                  Expanded(
                      child: ImageEditorActionButton(
                          key: const Key('image-editor-crop-reset'),
                          label: '还原',
                          onPressed: _busy ? null : _restore)),
                  const SizedBox(width: WeChatSpacing.md),
                  Expanded(
                      child: ImageEditorActionButton(
                          key: const Key('image-editor-apply-crop'),
                          label: '应用裁剪',
                          filled: true,
                          onPressed:
                              _busy || !_canApplyCrop ? null : _applyCrop)),
                ])),
          Align(
              alignment: Alignment.centerRight,
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: CupertinoButton.filled(
                      key: const Key('image-editor-done'),
                      onPressed: _busy ? null : _finish,
                      child: _busy
                          ? const CupertinoActivityIndicator()
                          : const Text('完成')))),
        ],
      ])));

  Widget _cropOptions() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.md),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          CupertinoButton(
              key: const Key('image-editor-crop-rotate'),
              padding: const EdgeInsets.symmetric(
                  horizontal: WeChatSpacing.sm, vertical: WeChatSpacing.xs),
              minimumSize: Size.zero,
              onPressed: _busy ? null : _rotate,
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(CupertinoIcons.rotate_right,
                    size: 16, color: CupertinoColors.white),
                SizedBox(width: 4),
                Text('旋转',
                    style:
                        TextStyle(color: CupertinoColors.white, fontSize: 13)),
              ])),
          const SizedBox(width: WeChatSpacing.sm),
          for (final entry in _cropAspects)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: CupertinoButton(
                    key: Key('image-editor-crop-aspect-${entry.id}'),
                    padding: const EdgeInsets.symmetric(
                        horizontal: WeChatSpacing.sm, vertical: 6),
                    minimumSize: Size.zero,
                    color: _cropAspect == entry.aspect
                        ? WeChatColors.brandPrimary
                        : const Color(0x33FFFFFF),
                    borderRadius:
                        BorderRadius.circular(WeChatRadius.networkCapsule),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _cropAspect = entry.aspect;
                              final frame = _cropFrame;
                              final bounds = _cropBounds;
                              if (entry.aspect != null &&
                                  frame != null &&
                                  bounds != null) {
                                _cropFrame = ImageCropGeometry.applyAspect(
                                    frame, entry.aspect!, bounds);
                              }
                            }),
                    child: Text(entry.label,
                        style: const TextStyle(
                            color: CupertinoColors.white, fontSize: 13)))),
        ]),
        const Text('拖动边框或四角调整裁剪范围，双指缩放 / 拖动画面',
            textAlign: TextAlign.center,
            style: TextStyle(color: CupertinoColors.white, fontSize: 12)),
      ]));
}

/// 编辑操作按钮（还原 / 应用裁剪）：**高度、圆角、间距完全一致**，
/// 只有「应用裁剪」用品牌色填充并带高亮状态。
final class ImageEditorActionButton extends StatelessWidget {
  const ImageEditorActionButton(
      {super.key,
      required this.label,
      this.onPressed,
      this.filled = false});

  static const double height = 44;
  static const double radius = WeChatRadius.bubble;

  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final background = filled
        ? (enabled ? WeChatColors.brandPrimary : const Color(0x33FFFFFF))
        : const Color(0x26FFFFFF);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      pressedOpacity: filled ? 0.7 : 0.5,
      onPressed: onPressed,
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(radius),
          border: filled
              ? null
              : Border.all(color: const Color(0x66FFFFFF), width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: enabled ? CupertinoColors.white : CupertinoColors.systemGrey,
          ),
        ),
      ),
    );
  }
}

class _ImageEditorEraserIcon extends StatelessWidget {
  const _ImageEditorEraserIcon(
      {required this.semanticLabel, required this.color});
  final String semanticLabel;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
      label: semanticLabel,
      child: CustomPaint(
          size: const Size.square(WeChatSpacing.xl),
          painter: _ImageEditorEraserPainter(color)));
}

class _ImageEditorEraserPainter extends CustomPainter {
  const _ImageEditorEraserPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final body = Path()
      ..moveTo(6, 16)
      ..lineTo(15, 7)
      ..quadraticBezierTo(16, 6, 17, 7)
      ..lineTo(20, 10)
      ..quadraticBezierTo(21, 11, 20, 12)
      ..lineTo(12, 20)
      ..close();
    canvas.drawPath(body, paint);
    canvas.drawLine(const Offset(5, 20), const Offset(10, 20), paint);
  }

  @override
  bool shouldRepaint(covariant _ImageEditorEraserPainter oldDelegate) =>
      oldDelegate.color != color;
}

class ImageEditorPainter extends CustomPainter {
  ImageEditorPainter(this.image, this.mosaic, this.document,
      {this.canvasSize,
      this.selection,
      this.viewScale = 1,
      this.viewOffset = Offset.zero,
      this.activeHandle = CropHandle.none});
  final ui.Image image, mosaic;
  final ImageEditDocument document;

  /// 画布尺寸（用于把 [selection] / 图片映射到屏幕）；为空时退回绘制尺寸。
  final Size? canvasSize;

  /// 裁剪框（画布坐标）；非空即绘制遮罩、边框、四角控制点与参考线。
  final Rect? selection;

  /// 用户在裁剪会话中的缩放（1 = 适配）与平移。
  final double viewScale;
  final Offset viewOffset;

  /// 正在拖动的控制点（高亮）。
  final CropHandle activeHandle;

  /// 图片按 contain 适配后的矩形（画布坐标，不含缩放/平移）。
  Rect viewBoxFor(Size size) {
    final extent = (canvasSize != null && !canvasSize!.isEmpty)
        ? canvasSize!
        : size;
    final crop = document.crop.size;
    if (extent.isEmpty || crop.isEmpty) return Rect.zero;
    final fitted = applyBoxFit(BoxFit.contain, crop, extent).destination;
    return Alignment.center.inscribe(fitted, Offset.zero & extent);
  }

  /// 测试与命中测试使用的图片适配矩形。
  Rect get viewBox => viewBoxFor(canvasSize ?? Size.zero);

  @override
  void paint(Canvas canvas, Size size) {
    final extent = (canvasSize != null && !canvasSize!.isEmpty)
        ? canvasSize!
        : size;
    final base = viewBoxFor(size);
    canvas.save();
    canvas.clipRect(Offset.zero & extent);
    if (!base.isEmpty && document.crop.width > 0) {
      final scale = base.width / document.crop.width * viewScale;
      final center = base.center + viewOffset;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.scale(scale);
      canvas.translate(-document.crop.center.dx, -document.crop.center.dy);
      paintImageDocument(canvas, image, mosaic, document);
      canvas.restore();
    }
    canvas.restore();
    final frame = selection;
    if (frame != null) _paintCropOverlay(canvas, extent, frame);
  }

  /// 半透明遮罩 + 明显边框 + 四角控制点 + 四边拖动提示 + 三分参考线。
  void _paintCropOverlay(Canvas canvas, Size size, Rect frame) {
    final mask = Paint()..color = const Color(0x99000000);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, frame.top), mask);
    canvas.drawRect(
        Rect.fromLTRB(0, frame.bottom, size.width, size.height), mask);
    canvas.drawRect(
        Rect.fromLTRB(0, frame.top, frame.left, frame.bottom), mask);
    canvas.drawRect(
        Rect.fromLTRB(frame.right, frame.top, size.width, frame.bottom), mask);

    final grid = Paint()
      ..color = const Color(0x4DFFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), grid);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), grid);
    }

    canvas.drawRect(
        frame,
        Paint()
          ..color = const Color(0xF2FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    const arm = 20.0;
    final handlePaint = Paint()
      ..color = activeHandle == CropHandle.none
          ? CupertinoColors.white
          : WeChatColors.brandPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    void corner(Offset point, double sx, double sy) {
      canvas.drawLine(point, point + Offset(arm * sx, 0), handlePaint);
      canvas.drawLine(point, point + Offset(0, arm * sy), handlePaint);
    }

    corner(frame.topLeft, 1, 1);
    corner(frame.topRight, -1, 1);
    corner(frame.bottomLeft, 1, -1);
    corner(frame.bottomRight, -1, -1);

    final edgePaint = Paint()
      ..color = const Color(0xE6FFFFFF)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const half = 10.0;
    canvas.drawLine(Offset(frame.center.dx - half, frame.top),
        Offset(frame.center.dx + half, frame.top), edgePaint);
    canvas.drawLine(Offset(frame.center.dx - half, frame.bottom),
        Offset(frame.center.dx + half, frame.bottom), edgePaint);
    canvas.drawLine(Offset(frame.left, frame.center.dy - half),
        Offset(frame.left, frame.center.dy + half), edgePaint);
    canvas.drawLine(Offset(frame.right, frame.center.dy - half),
        Offset(frame.right, frame.center.dy + half), edgePaint);
  }

  @override
  bool shouldRepaint(covariant ImageEditorPainter oldDelegate) =>
      oldDelegate.document != document ||
      oldDelegate.selection != selection ||
      oldDelegate.viewScale != viewScale ||
      oldDelegate.viewOffset != viewOffset ||
      oldDelegate.activeHandle != activeHandle ||
      oldDelegate.canvasSize != canvasSize;
}
