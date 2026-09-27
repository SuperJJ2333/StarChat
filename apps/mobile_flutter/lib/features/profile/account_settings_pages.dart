import 'dart:async';
import 'package:flutter/cupertino.dart';
import '../../core/account_credentials_gateway.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/auth_surface_card.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/motion/motion_page_route.dart';
import '../auth/email_rebind_page.dart';
import '../auth/password_change_page.dart';
import '../auth/phone_rebind_page.dart';

final class AccountSecurityPage extends StatefulWidget {
  const AccountSecurityPage(
      {super.key,
      required this.api,
      required this.onPasswordChanged,
      this.onBindingsChanged});
  final BusinessApiClient api;
  final Future<void> Function() onPasswordChanged;
  final Future<void> Function()? onBindingsChanged;
  @override
  State<AccountSecurityPage> createState() => _AccountSecurityPageState();
}

final class _AccountSecurityPageState extends State<AccountSecurityPage> {
  AccountSecurityData? _security;
  bool _loading = true;
  String? _error;
  int _operation = 0;
  bool _current(int operation, int epoch) =>
      mounted && operation == _operation && epoch == widget.api.sessionEpoch;
  @override
  void initState() {
    super.initState();
    _security = widget.api.cachedAccountSecurityData;
    _loading = _security == null;
    _load();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final operation = ++_operation;
    final epoch = widget.api.sessionEpoch;
    setState(() {
      _loading = _security == null;
      _error = null;
    });
    try {
      final value = await widget.api
          .loadAccountSecurity(forceRefresh: forceRefresh)
          .timeout(const Duration(seconds: 8));
      if (_current(operation, epoch)) setState(() => _security = value);
    } catch (_) {
      if (_current(operation, epoch)) {
        setState(() {
          final pending = widget.api.hasPendingAccountBindingConfirmation;
          if (pending) _security = null;
          _error = pending ? '绑定结果待确认，请稍后重试' : '账号信息加载失败，请重试';
        });
        if (widget.api.hasPendingAccountBindingConfirmation) {
          unawaited(_reconcileBinding(operation, epoch));
        }
      }
    } finally {
      if (_current(operation, epoch)) setState(() => _loading = false);
    }
  }

  Future<void> _reconcileBinding(int operation, int epoch) async {
    await widget.api.waitForAccountBindingConfirmation();
    if (!_current(operation, epoch)) return;
    await _load(forceRefresh: true);
    if (_current(operation + 1, epoch) && _error == null) {
      await widget.onBindingsChanged?.call();
    }
  }

  Future<void> _openBinding(Widget page) async {
    final epoch = widget.api.sessionEpoch;
    await Navigator.of(context)
        .push<bool>(MotionPageRoute(builder: (_) => page));
    if (!mounted || epoch != widget.api.sessionEpoch) return;
    // Always re-read authoritative bindings. A lost confirmation response can
    // still have completed server-side, even when no success result was popped.
    widget.api.invalidateAccountSecurityCache();
    setState(() => _security = null);
    await _load(forceRefresh: true);
    if (mounted &&
        epoch == widget.api.sessionEpoch &&
        !widget.api.hasPendingAccountBindingConfirmation) {
      await widget.onBindingsChanged?.call();
    }
  }

  Widget _row(String label, String detail, VoidCallback? onTap) =>
      WeChatListTile(
          title: Text(label),
          subtitle: Text(detail),
          trailing: const CupertinoListTileChevron(),
          showDivider: true,
          onTap: onTap);
  String _bindingSummary(
      {required bool bound, required bool verified, String? masked}) {
    if (!bound) return '未绑定';
    if (!verified) return '待验证';
    return masked?.trim().isNotEmpty == true ? masked! : '已绑定';
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
      title: '账号安全',
      child: SafeArea(
          child: ListView(
              padding: const EdgeInsets.all(WeChatSpacing.md),
              children: [
            if (_loading)
              const Center(child: CupertinoActivityIndicator())
            else if (_security != null) ...[
              _row(
                  _security!.phoneBound ? '更换手机号' : '绑定手机号',
                  _bindingSummary(
                      bound: _security!.phoneBound,
                      verified: _security!.phoneVerified,
                      masked: _security!.maskedPhone),
                  _error == null &&
                          (_security!.canUsePhone || _security!.canUseEmail)
                      ? () => _openBinding(PhoneRebindPage(api: widget.api))
                      : null),
              _row(
                  _security!.emailBound ? '更换邮箱' : '绑定邮箱',
                  _bindingSummary(
                      bound: _security!.emailBound,
                      verified: _security!.emailVerified,
                      masked: _security!.maskedEmail),
                  _error == null &&
                          (_security!.canUsePhone || _security!.canUseEmail)
                      ? () => _openBinding(EmailRebindPage(gateway: widget.api))
                      : null),
              _row(
                  '更换密码',
                  '使用已绑定邮箱或手机验证码验证',
                  _error != null
                      ? null
                      : () => Navigator.of(context).push(MotionPageRoute(
                          builder: (_) => PasswordChangePage(
                              gateway: widget.api,
                              authenticated: true,
                              security: _security,
                              onCompleted: widget.onPasswordChanged)))),
              if (!_security!.canUseEmail && !_security!.canUsePhone)
                const Padding(
                    padding: EdgeInsets.all(WeChatSpacing.md),
                    child: Text('当前账号没有可用的已验证联系方式，请联系客服。')),
            ],
            if (_error != null) ...[
              AuthErrorMessage(message: _error!),
              const SizedBox(height: WeChatSpacing.md),
              ModernActionButton(
                  icon: CupertinoIcons.refresh, label: '重试', onPressed: _load),
            ],
          ])));
}

final class ChatSettingsPage extends StatefulWidget {
  const ChatSettingsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

final class _ChatSettingsPageState extends State<ChatSettingsPage> {
  bool? _enabled;
  bool _loading = true, _saving = false;
  String? _error;
  int _operation = 0;

  bool _current(int operation, int epoch) =>
      mounted && operation == _operation && epoch == widget.api.sessionEpoch;
  @override
  void initState() {
    super.initState();
    _enabled = widget.api.cachedAutoAllowGroupJoin;
    _loading = _enabled == null;
    _load();
  }

  Future<void> _load() async {
    final operation = ++_operation;
    final epoch = widget.api.sessionEpoch;
    setState(() {
      _loading = _enabled == null;
      _saving = widget.api.hasPendingAutoAllowGroupJoinWrite;
      _error = null;
    });
    if (_saving) {
      try {
        await widget.api
            .waitForAutoAllowGroupJoinWrite()
            .timeout(const Duration(seconds: 8));
      } on TimeoutException {
        if (_current(operation, epoch)) {
          setState(() {
            _loading = false;
            _error = '保存结果待确认';
          });
          unawaited(_reconcile(operation, epoch));
        }
        return;
      }
    }
    await _readAuthority(operation, epoch);
  }

  Future<void> _readAuthority(int operation, int epoch) async {
    try {
      final value = await widget.api
          .autoAllowGroupJoin()
          .timeout(const Duration(seconds: 8));
      if (_current(operation, epoch)) {
        setState(() {
          _enabled = value;
          _saving = false;
          _error = null;
        });
      }
    } catch (_) {
      if (_current(operation, epoch)) {
        setState(() {
          _enabled = null;
          _saving = false;
          _error = '聊天设置加载失败，请重试';
        });
      }
    } finally {
      if (_current(operation, epoch)) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reconcile(int operation, int epoch) async {
    await widget.api.waitForAutoAllowGroupJoinWrite();
    if (_current(operation, epoch)) {
      await _readAuthority(operation, epoch);
    }
  }

  Future<void> _update(bool value) async {
    if (_saving || _enabled == null) {
      return;
    }
    final operation = ++_operation;
    final epoch = widget.api.sessionEpoch;
    final previous = _enabled;
    setState(() {
      _enabled = value;
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.api
          .setAutoAllowGroupJoin(value)
          .timeout(const Duration(seconds: 8));
      if (_current(operation, epoch)) {
        setState(() {
          _enabled = saved;
          _saving = false;
        });
      }
    } on TimeoutException {
      if (_current(operation, epoch)) {
        setState(() => _error = '保存结果待确认');
        unawaited(_reconcile(operation, epoch));
      }
    } catch (_) {
      if (_current(operation, epoch)) {
        setState(() {
          _enabled = previous;
          _error = '保存失败，请重试';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
      title: '聊天',
      child: SafeArea(
          child: ListView(
              padding: const EdgeInsets.all(WeChatSpacing.md),
              children: [
            if (_loading)
              const Center(child: CupertinoActivityIndicator())
            else if (_enabled != null)
              WeChatListTile(
                  title: const Text('是否自动允许加入群聊'),
                  subtitle: const Text('开启后，好友邀请你加入群聊时将自动加入'),
                  showDivider: true,
                  trailing: CupertinoSwitch(
                      key: const Key('chat-auto-group-join'),
                      value: _enabled!,
                      onChanged: _saving ? null : _update)),
            if (_error != null) ...[
              const SizedBox(height: WeChatSpacing.md),
              AuthErrorMessage(message: _error!),
              if (_enabled == null && !_saving)
                ModernActionButton(
                    icon: CupertinoIcons.refresh, label: '重试', onPressed: _load)
            ],
          ])));
}
