import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../core/username_gateway.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'profile_controller.dart';

final class UsernameChangePage extends StatefulWidget {
  const UsernameChangePage(
      {super.key, required this.gateway, required this.controller});
  final UsernameGateway gateway;
  final ProfileController controller;
  @override
  State<UsernameChangePage> createState() => _UsernameChangePageState();
}

final class _UsernameChangePageState extends State<UsernameChangePage> {
  late final _input = TextEditingController(
      text: widget.controller.state.profile?.username ?? '');
  late final int _epoch = widget.gateway.sessionEpoch;
  UsernameChangePolicy? _policy;
  Timer? _debounce;
  int _revision = 0;
  bool _loading = true, _checking = false, _saving = false;
  bool? _available;
  String? _error;
  String? _submittedDraft, _idempotencyKey;
  bool get _current => mounted && _epoch == widget.gateway.sessionEpoch;
  bool get _valid =>
      RegExp(r'^[A-Za-z][A-Za-z0-9_-]{5,19}$').hasMatch(_input.text.trim());
  bool get _same =>
      _input.text.trim().toLowerCase() == _policy?.username.toLowerCase();

  @override
  void initState() {
    super.initState();
    _input.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _revision++;
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final policy = await widget.gateway.loadUsernameChangePolicy();
      if (!_current) return;
      setState(() => _policy = policy);
      _input.text = policy.username;
      await widget.controller.applyUsername(policy.username);
    } catch (_) {
      if (_current) setState(() => _error = '畅聊号信息加载失败，请重试');
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  void _changed() {
    _debounce?.cancel();
    final revision = ++_revision;
    setState(() {
      _available = null;
      _error = null;
      _checking = false;
    });
    if (!_valid || _same || _policy?.canChange != true || _saving) return;
    setState(() => _checking = true);
    final draft = _input.text.trim();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final available = await widget.gateway.usernameAvailable(draft);
        if (_current && revision == _revision) {
          setState(() => _available = available);
        }
      } catch (_) {
        if (_current && revision == _revision) {
          setState(() => _error = '暂时无法检查，请重新输入或稍后重试');
        }
      } finally {
        if (_current && revision == _revision) {
          setState(() => _checking = false);
        }
      }
    });
  }

  Future<void> _save() async {
    if (_saving ||
        _policy?.canChange != true ||
        !_valid ||
        (!_same && _available != true)) {
      return;
    }
    final draft = _input.text.trim();
    if (_submittedDraft != draft) {
      _submittedDraft = draft;
      _idempotencyKey = widget.gateway.newIdempotencyKey();
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final receipt = await widget.gateway
          .changeUsername(draft, idempotencyKey: _idempotencyKey!);
      if (!_current) return;
      await widget.controller.applyUsername(receipt.username);
      if (mounted && _current) Navigator.pop(context, receipt);
    } on BusinessApiException catch (error) {
      if (_current) {
        setState(() => _error = switch (error.code) {
              'USERNAME_TAKEN' => '该畅聊号已被使用，请换一个',
              'USERNAME_CHANGE_COOLDOWN' => '修改机会尚未恢复，请稍后再试',
              'USERNAME_INVALID' => '请输入6–20位字母、数字、下划线或连字符，并以字母开头',
              _ => '修改失败，请重试',
            });
      }
      if (_current && error.code == 'USERNAME_CHANGE_COOLDOWN') {
        final policy = _policy!;
        setState(() => _policy = UsernameChangePolicy(
            username: policy.username,
            canChange: false,
            nextChangeAt: policy.nextChangeAt));
        try {
          final fresh = await widget.gateway.loadUsernameChangePolicy();
          if (_current) setState(() => _policy = fresh);
        } catch (_) {
          // The explicit server rejection keeps edits disabled until a fresh
          // page can obtain an authoritative policy.
        }
      }
    } catch (_) {
      if (_current) setState(() => _error = '修改失败，请重试');
    } finally {
      if (_current) setState(() => _saving = false);
    }
  }

  String _cooldown(UsernameChangePolicy policy) {
    final at = policy.nextChangeAt?.toLocal();
    return at == null
        ? '修改机会尚未恢复'
        : '下次可修改：${at.year}年${at.month}月${at.day}日 ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final policy = _policy;
    final enabled = !_loading && !_saving && policy?.canChange == true;
    return WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: const Text('修改畅聊号'),
            trailing: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: enabled && _valid && (_same || _available == true)
                    ? _save
                    : null,
                child: const Text('保存'))),
        child: SafeArea(
            child: ListView(
                padding: const EdgeInsets.all(WeChatSpacing.md),
                children: [
              if (_loading)
                const Center(child: CupertinoActivityIndicator())
              else if (policy != null) ...[
                Container(
                    color: WeChatColors.elevatedSurface(context),
                    padding: const EdgeInsets.all(WeChatSpacing.lg),
                    child: Row(children: [
                      const Text('畅聊号',
                          style: TextStyle(fontSize: WeChatTypography.body)),
                      const SizedBox(width: WeChatSpacing.lg),
                      Expanded(
                          child: CupertinoTextField(
                              key: const Key('profile-username-field'),
                              controller: _input,
                              textAlign: TextAlign.right,
                              maxLength: 20,
                              enabled: enabled,
                              autocorrect: false,
                              enableSuggestions: false,
                              padding: EdgeInsets.zero,
                              decoration: null,
                              style: TextStyle(
                                  fontSize: WeChatTypography.body,
                                  color: WeChatColors.resolveTextPrimary(
                                      context))))
                    ])),
                const Padding(
                    padding: EdgeInsets.only(top: WeChatSpacing.md),
                    child: Text('6–20位，以字母开头，可使用字母、数字、下划线和连字符；大小写不区分。')),
                const Padding(
                    padding: EdgeInsets.only(top: WeChatSpacing.sm),
                    child: Text('每365天可以修改一次。修改后请使用新畅聊号登录和搜索。')),
                if (!policy.canChange)
                  Padding(
                      padding: const EdgeInsets.only(top: WeChatSpacing.md),
                      child: Text(_cooldown(policy))),
                if (_checking)
                  const Padding(
                      padding: EdgeInsets.only(top: WeChatSpacing.md),
                      child: Text('正在检查畅聊号…')),
                if (_available != null)
                  Padding(
                      padding: const EdgeInsets.only(top: WeChatSpacing.md),
                      child: Text(_available! ? '该畅聊号可以使用' : '该畅聊号已被使用，请换一个',
                          style: TextStyle(
                              color: _available!
                                  ? WeChatColors.brandPrimary
                                  : CupertinoColors.systemRed))),
              ],
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: WeChatSpacing.md),
                    child: Text(_error!,
                        style:
                            const TextStyle(color: CupertinoColors.systemRed))),
              if (!_loading && policy == null)
                ModernActionButton(
                    icon: CupertinoIcons.refresh,
                    label: '重试',
                    onPressed: _load),
              if (enabled && _valid && _available == null && _error != null)
                ModernActionButton(
                    icon: CupertinoIcons.refresh,
                    label: '重试',
                    onPressed: _changed),
            ])));
  }
}
