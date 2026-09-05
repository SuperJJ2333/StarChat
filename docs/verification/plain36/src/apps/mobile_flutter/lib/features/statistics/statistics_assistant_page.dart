import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show LinearProgressIndicator;
import 'package:webview_flutter/webview_flutter.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'statistics_state_store.dart';

/// 统计助手：全屏 WebView 页面，加载本地 H5 资源，并通过 JS 通道与会话缓存桥接。
///
/// - 页面加载完成后注入会话状态（roomId + 主题 + 缓存的工具状态）。
/// - HTML 每次操作后经 `statsBridge` 通道推送最新状态，本页防抖落盘到
///   [StatisticsStateStore]（按会话隔离）。
/// - 销毁前 best-effort 读回一次作为安全网。
final class StatisticsAssistantPage extends StatefulWidget {
  const StatisticsAssistantPage({super.key, required this.roomId});

  /// 当前会话的 Matrix room id（会话缓存隔离的键）。
  final String roomId;

  @override
  State<StatisticsAssistantPage> createState() => _StatisticsAssistantPageState();
}

final class _StatisticsAssistantPageState extends State<StatisticsAssistantPage> {
  late final WebViewController _controller;
  Brightness _brightness = Brightness.light;
  int _progress = 0;
  bool _pageFinished = false;
  String? _pendingJson;
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'statsBridge',
        onMessageReceived: _handleBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _pageFinished = true;
            unawaited(_injectInitState());
          },
          onProgress: (progress) => setState(() => _progress = progress),
        ),
      )
      ..loadFlutterAsset('assets/html/statistics_tools_combined_v2.html');
  }

  /// 主题跟随 App 深浅色；页面已加载完成时热更新 HTML 的 data-theme。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = CupertinoTheme.brightnessOf(context);
    if (brightness != _brightness) {
      _brightness = brightness;
      if (_pageFinished) {
        unawaited(_controller.runJavaScript(
          'window.__statsSetTheme("${brightness == Brightness.dark ? 'dark' : 'light'}")',
        ));
      }
    }
  }

  /// 页面加载完成 → 读会话缓存 → 注入状态与主题。
  Future<void> _injectInitState() async {
    final stored = await StatisticsStateStore.read(widget.roomId);
    final init = <String, Object?>{
      'roomId': widget.roomId,
      'theme': _brightness == Brightness.dark ? 'dark' : 'light',
      'state': stored == null ? null : jsonDecode(stored),
    };
    await _controller.runJavaScript('window.__statsInit(${jsonEncode(init)})');
  }

  /// JS 通道：HTML 每次操作后防抖推送 `{type:'save', state:<json字符串>}`。
  void _handleBridgeMessage(JavaScriptMessage message) {
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is Map<String, Object?> && decoded['type'] != 'save') return;
      final stateJson = decoded is Map<String, Object?> ? decoded['state'] : null;
      if (stateJson is! String) return;
      _pendingJson = stateJson;
      _saveDebounce?.cancel();
      _saveDebounce = Timer(
        const Duration(milliseconds: 600),
        () => unawaited(_persist()),
      );
    } catch (_) {
      // 非法消息忽略
    }
  }

  Future<void> _persist() async {
    final json = _pendingJson;
    if (json == null || json.isEmpty) return;
    await StatisticsStateStore.write(widget.roomId, json);
  }

  /// 页面销毁前尝试读回一次最新状态（运行期防抖保存为主，此为安全网）。
  Future<void> _finalReadback() async {
    try {
      final result =
          await _controller.runJavaScriptReturningResult('window.__statsGetState()');
      final json = _unwrapJsString(result);
      if (json.isNotEmpty) {
        await StatisticsStateStore.write(widget.roomId, json);
      }
    } catch (_) {
      // WebView 已拆除，静默忽略
    }
  }

  /// Android 会把 JS 字符串结果再做一次 JSON 序列化，这里解一层。
  static String _unwrapJsString(Object? result) {
    final raw = result?.toString().trim() ?? '';
    if (raw.isEmpty || raw == 'null') return '';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is String) return decoded;
      return raw;
    } catch (_) {
      return raw;
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    unawaited(_finalReadback());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text(
          '统计助手',
          style: TextStyle(fontSize: WeChatTypography.body),
        ),
      ),
      child: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_progress < 100)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress / 100,
                minHeight: 2,
                color: WeChatColors.brandPrimary,
              ),
            ),
        ],
      ),
    );
  }
}
