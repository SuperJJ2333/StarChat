import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import 'manual_wallet_api.dart';
import 'manual_operation_store.dart';

final class ManualMfaPage extends StatefulWidget {
  const ManualMfaPage({super.key, required this.client});
  final BusinessApiClient client;
  @override
  State<ManualMfaPage> createState() => _ManualMfaPageState();
}

final class _ManualMfaPageState extends State<ManualMfaPage> {
  final password = TextEditingController();
  final code = TextEditingController();
  ManualMfaEnrollment? enrollment;
  ManualMfaStatus? status;
  String? message;
  String? credentialId;
  String? setupProof;
  bool busy = false;
  late final api = ManualWalletApi(widget.client);
  late final store = ManualOperationStore(widget.client);

  @override
  void initState() {
    super.initState();
    run(() async {
      await store.initialize();
      credentialId = (await store.read('mfa'))?['id'] as String?;
      await refresh();
    });
  }

  Future<void> refresh() async {
    status = await api.mfaStatus();
    if (status!.enabled) {
      setupProof = null;
      enrollment = null;
      credentialId = null;
      await store.clear('mfa');
    } else if (status!.pendingCredentialId != null) {
      credentialId = status!.pendingCredentialId;
      await store.save('mfa', {'id': credentialId});
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (error) {
      if (error is BusinessApiException &&
          {'MFA_SETUP_PROOF_INVALID', 'RECENT_LOGIN_REQUIRED'}
              .contains(error.code)) {
        setupProof = null;
      }
      message = error is BusinessApiException
          ? '${error.message}（${error.code}）'
          : '操作结果未确认，请先刷新安全状态后再操作';
    } finally {
      if (mounted) {
        password.clear();
        code.clear();
        setState(() => busy = false);
      }
    }
  }

  @override
  void dispose() {
    password.dispose();
    code.dispose();
    enrollment = null;
    setupProof = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(middle: Text('安全验证')),
        child: SafeArea(
            child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('设置账号安全验证',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Text(status?.enabled == true
              ? '身份验证器已启用。绑定或提现时输入当前六位验证码。'
              : '六位动态码由身份验证器生成，用于确认绑定和提现操作是你本人发起。它不是短信验证码，也不是钱包密码。'),
          if (status?.enabled != true) ...[
            const SizedBox(height: 12),
            const Text('设置步骤：验证登录密码 → 将下方二维码或设置密钥添加到身份验证器 → 输入生成的六位动态码并启用。'),
            const SizedBox(height: 8),
            const Text(
                '同一部手机无法扫描自己的屏幕时，可在身份验证器中选择手动添加并输入设置密钥。请勿分享二维码、设置密钥或验证码。'),
          ],
          CupertinoButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                        await refresh();
                      }),
              child: const Text('刷新安全状态')),
          if (status?.enabled == false &&
              credentialId == null &&
              status?.enrolledAt != null)
            const Text('存在未完成的验证器配置，但本机缺少配置编号。请联系管理员恢复；不要重复创建配置。'),
          if (status?.enabled == false &&
              credentialId == null &&
              status?.enrolledAt == null) ...[
            CupertinoTextField(
                key: const Key('manual-mfa-password'),
                controller: password,
                placeholder: '登录密码',
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false),
            ModernActionButton(
              icon: CupertinoIcons.lock_shield,
              label: '设置身份验证器',
              onPressed: busy || status?.configured != true
                  ? null
                  : () => run(() async {
                        await store.read('mfa');
                        await refresh();
                        if (status!.enabled || credentialId != null) return;
                        enrollment = await api.enrollMfa(
                            password: password.text,
                            idempotencyKey: widget.client.newIdempotencyKey());
                        credentialId = enrollment!.credentialId;
                        setupProof = enrollment!.setupProof;
                        await store.save('mfa', {'id': credentialId});
                      }),
            ),
          ],
          if (enrollment != null) ...[
            Center(
                child: QrImageView(
                    data: enrollment!.provisioningUri,
                    size: 200,
                    backgroundColor: CupertinoColors.white)),
            Text(enrollment!.secret, textAlign: TextAlign.center),
          ],
          if (credentialId != null && status?.enabled == false) ...[
            if (setupProof == null) ...[
              const Text('在此验证登录密码即可继续，无需退出账号。验证仅用于本次安全设置，5 分钟内有效。'),
              CupertinoTextField(
                  key: const Key('manual-mfa-reauth-password'),
                  controller: password,
                  placeholder: '当前登录密码',
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false),
              CupertinoButton(
                  key: const Key('manual-mfa-reauth'),
                  onPressed: busy
                      ? null
                      : () => run(() async {
                            setupProof = await api.reauthenticateMfa(
                                credentialId: credentialId!,
                                password: password.text,
                                idempotencyKey:
                                    widget.client.newIdempotencyKey());
                            message = '身份已确认，请输入验证器动态码并启用';
                          }),
                  child: const Text('验证密码并继续')),
            ],
            if (enrollment == null)
              const Text('输入已添加验证器的验证码。若未保存验证器，请取消本次设置后重新设置。'),
            CupertinoTextField(
                key: const Key('manual-mfa-code'),
                controller: code,
                placeholder: '六位验证码',
                keyboardType: TextInputType.number,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false),
            ModernActionButton(
              icon: CupertinoIcons.checkmark_shield,
              label: '验证并启用',
              onPressed: busy || status?.configured != true
                  ? null
                  : () => run(() async {
                        await store.read('mfa');
                        await api.enableMfa(
                            credentialId: credentialId!,
                            code: code.text.trim(),
                            setupProof: setupProof,
                            idempotencyKey: widget.client.newIdempotencyKey());
                        enrollment = null;
                        await refresh();
                      }),
            ),
            CupertinoTextField(
                controller: password,
                placeholder: '取消设置需重新输入登录密码',
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false),
            CupertinoButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                          await store.read('mfa');
                          await api.abortMfaEnrollment(
                              credentialId: credentialId!,
                              password: password.text,
                              idempotencyKey:
                                  widget.client.newIdempotencyKey());
                          enrollment = null;
                          setupProof = null;
                          credentialId = null;
                          await store.clear('mfa');
                          await refresh();
                        }),
                child: const Text('取消本次设置')),
          ],
          if (busy) const CupertinoActivityIndicator(),
          if (message != null) Text(message!),
        ])),
      );
}
