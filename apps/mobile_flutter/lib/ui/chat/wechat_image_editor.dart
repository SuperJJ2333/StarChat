import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../core/gallery_save_access.dart';
import '../components/wechat_scaffold.dart';
import '../foundation/wechat_tokens.dart';

enum ImageEditTool { brush, emoji, text, crop, mosaic }

/// All coordinates are in decoded image pixels, independent of viewport/crop.
@immutable
class ImageEditMark {
  const ImageEditMark(
      {required this.points,
      required this.color,
      required this.width,
      this.text,
      this.mosaic = false});
  final List<Offset> points;
  final Color color;
  final double width;
  final String? text;
  final bool mosaic;
  ImageEditMark moved(Offset delta) => ImageEditMark(
      points: points.map((point) => point + delta).toList(),
      color: color,
      width: width,
      text: text,
      mosaic: mosaic);
}

@immutable
class ImageEditDocument {
  const ImageEditDocument(this.crop, this.marks);
  final Rect crop;
  final List<ImageEditMark> marks;
}

final class WeChatImageEditorPage extends StatefulWidget {
  const WeChatImageEditorPage(
      {super.key, required this.bytes, this.onForward, this.onFavorite});
  final Uint8List bytes;
  final Future<bool> Function(Uint8List)? onForward;
  final Future<void> Function(Uint8List)? onFavorite;
  @override
  State<WeChatImageEditorPage> createState() => _WeChatImageEditorPageState();
}

class _WeChatImageEditorPageState extends State<WeChatImageEditorPage> {
  ui.Image? _image, _mosaic;
  final _history = <ImageEditDocument>[];
  int _cursor = -1;
  ImageEditTool _tool = ImageEditTool.brush;
  Color _color = CupertinoColors.white;
  double _width = 5;
  List<Offset> _stroke = [];
  Offset? _start, _last;
  Rect? _cropSelection;
  int? _movingMark;
  List<ImageEditMark>? _movingMarks;
  bool _busy = false;
  String? _error;
  ImageEditDocument get _doc => _history[_cursor];

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

  void _commit(ImageEditDocument next) {
    setState(() {
      _history.removeRange(_cursor + 1, _history.length);
      _history.add(next);
      _cursor++;
      _stroke = [];
      _movingMarks = null;
      _cropSelection = null;
    });
  }

  Future<void> _addText({bool emoji = false}) async {
    String? value;
    if (emoji) {
      value = await showCupertinoModalPopup<String>(
          context: context,
          builder: (context) => Container(
              height: 280,
              color: CupertinoColors.systemBackground.resolveFrom(context),
              child: SafeArea(
                  child: GridView.count(crossAxisCount: 7, children: [
                for (final item in const [
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
                  '🎁'
                ])
                  CupertinoButton(
                      onPressed: () => Navigator.pop(context, item),
                      child: Text(item, style: const TextStyle(fontSize: 28)))
              ]))));
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
    _commit(ImageEditDocument(_doc.crop, [
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
      _cropSelection = null;
    });
    if (tool == ImageEditTool.emoji || tool == ImageEditTool.text) {
      _addText(emoji: tool == ImageEditTool.emoji);
    }
  }

  Offset _point(Offset local, Size size) => Offset(
      (_doc.crop.left + local.dx / size.width * _doc.crop.width)
          .clamp(_doc.crop.left, _doc.crop.right),
      (_doc.crop.top + local.dy / size.height * _doc.crop.height)
          .clamp(_doc.crop.top, _doc.crop.bottom));

  void _panStart(Offset local, Size size) {
    final point = _point(local, size);
    _start = _last = point;
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
    } else if (_tool != ImageEditTool.crop) {
      setState(() => _stroke = [point]);
    }
  }

  void _panUpdate(Offset local, Size size) {
    final point = _point(local, size);
    setState(() {
      if (_tool == ImageEditTool.crop && _start != null) {
        _cropSelection = Rect.fromPoints(_start!, point);
      } else if (_movingMark != null) {
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
      _commit(ImageEditDocument(_doc.crop, _movingMarks!));
    } else if (_stroke.isNotEmpty) {
      _commit(ImageEditDocument(_doc.crop, [
        ..._doc.marks,
        ImageEditMark(
            points: List.of(_stroke),
            color: _color,
            width: _doc.crop.width / 350 * _width,
            mosaic: _tool == ImageEditTool.mosaic)
      ]));
    }
    _movingMark = null;
    _start = _last = null;
  }

  Future<Uint8List> _export() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final width = _doc.crop.width.round().clamp(1, 4096);
    final height = _doc.crop.height.round().clamp(1, 4096);
    ImageEditorPainter(_image!, _mosaic!, _doc)
        .paint(canvas, Size(width.toDouble(), height.toDouble()));
    final picture = recorder.endRecording();
    late ui.Image image;
    try {
      image = await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Image encoding failed');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _finish() async {
    if (_busy || _image == null) return;
    final action = await showCupertinoModalPopup<String>(
        context: context,
        builder: (context) => CupertinoActionSheet(
                actions: [
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
    try {
      final bytes = await _export();
      if (!mounted) return;
      var done = true;
      if (action == 'forward') {
        done = await widget.onForward!(bytes);
      } else if (action == 'favorite') {
        await widget.onFavorite!(bytes);
      } else {
        await ensureGallerySaveAccess();
        final saved = await PhotoManager.editor.saveImage(bytes,
            filename:
                'ChatFlow-edited-${DateTime.now().millisecondsSinceEpoch}.png');
        if (saved.id.isEmpty) throw StateError('Save failed');
      }
      if (mounted && done) {
        setState(() => _error = action == 'forward'
            ? '已转发'
            : action == 'favorite'
                ? '已收藏'
                : '已保存到相册');
      }
    } catch (error) {
      if (mounted)
        setState(() => _error = action == 'save'
            ? gallerySaveErrorMessage(error)
            : '操作失败，请重试，编辑内容已保留');
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
                          _cropSelection = null;
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
                          _cropSelection = null;
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
                    final fit = applyBoxFit(
                        BoxFit.contain, _doc.crop.size, constraints.biggest);
                    final size = fit.destination;
                    final document = ImageEditDocument(_doc.crop, [
                      ...(_movingMarks ?? _doc.marks),
                      if (_stroke.isNotEmpty)
                        ImageEditMark(
                            points: _stroke,
                            color: _color,
                            width: _doc.crop.width / 350 * _width,
                            mosaic: _tool == ImageEditTool.mosaic)
                    ]);
                    return Center(
                        child: SizedBox.fromSize(
                            size: size,
                            child: IgnorePointer(
                                ignoring: _busy,
                                child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onPanStart: (d) =>
                                        _panStart(d.localPosition, size),
                                    onPanUpdate: (d) =>
                                        _panUpdate(d.localPosition, size),
                                    onPanEnd: (_) => _panEnd(),
                                    onPanCancel: () => setState(() {
                                          _stroke = [];
                                          _movingMarks = null;
                                          _movingMark = null;
                                          _cropSelection = null;
                                        }),
                                    child: CustomPaint(
                                        painter: ImageEditorPainter(
                                            _image!, _mosaic!, document,
                                            selection: _cropSelection))))));
                  })),
        if (_error != null && _image != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!,
                  style: const TextStyle(color: CupertinoColors.white))),
        if (_image != null) ...[
          if (_tool == ImageEditTool.crop)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('拖动画面选择裁剪区域',
                  style: TextStyle(color: CupertinoColors.white)),
              CupertinoButton(
                  onPressed: !_busy &&
                          (_cropSelection?.width ?? 0) >= 16 &&
                          (_cropSelection?.height ?? 0) >= 16
                      ? () => _commit(
                          ImageEditDocument(_cropSelection!, _doc.marks))
                      : null,
                  child: const Text('应用裁剪'))
            ])
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
              (ImageEditTool.mosaic, CupertinoIcons.square_grid_3x2, '马赛克')
            ])
              CupertinoButton(
                  key: ValueKey('image-editor-${entry.$1.name}'),
                  padding: const EdgeInsets.all(8),
                  onPressed: _busy ? null : () => _selectTool(entry.$1),
                  child: Icon(entry.$2,
                      semanticLabel: entry.$3,
                      color: _tool == entry.$1
                          ? WeChatColors.brandPrimary
                          : CupertinoColors.white)),
          ]),
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
}

class ImageEditorPainter extends CustomPainter {
  ImageEditorPainter(this.image, this.mosaic, this.document, {this.selection});
  final ui.Image image, mosaic;
  final ImageEditDocument document;
  final Rect? selection;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(
        size.width / document.crop.width, size.height / document.crop.height);
    canvas.translate(-document.crop.left, -document.crop.top);
    final bounds =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImage(image, Offset.zero, Paint());
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
        canvas.drawImageRect(
            mosaic,
            Rect.fromLTWH(
                0, 0, mosaic.width.toDouble(), mosaic.height.toDouble()),
            bounds,
            Paint()..filterQuality = FilterQuality.none);
        canvas.restore();
      } else if (mark.points.isNotEmpty) {
        final paint = Paint()
          ..color = mark.color
          ..strokeWidth = mark.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;
        if (mark.points.length == 1) {
          canvas.drawCircle(
              mark.points.first, mark.width / 2, Paint()..color = mark.color);
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
    if (selection != null) {
      canvas.drawRect(
          selection!,
          Paint()
            ..color = CupertinoColors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = document.crop.width / size.width * 2);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ImageEditorPainter oldDelegate) =>
      oldDelegate.document != document || oldDelegate.selection != selection;
}
