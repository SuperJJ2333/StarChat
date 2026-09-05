import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import 'login_page.dart';
import 'registration_controller.dart';
import 'registration_page.dart';
import 'verification_page.dart';

enum _AuthPage { login, register, verify }

final class AuthenticationFlow extends StatefulWidget {
  const AuthenticationFlow(
      {super.key,
      required this.api,
      required this.onLogin,
      required this.onAuthenticated});
  final BusinessApiClient api;
  final Future<void> Function(String, String) onLogin;
  final Future<void> Function() onAuthenticated;
  @override
  State<AuthenticationFlow> createState() => _AuthenticationFlowState();
}

final class _AuthenticationFlowState extends State<AuthenticationFlow> {
  late final RegistrationController registration =
      RegistrationController(gateway: widget.api);
  _AuthPage page = _AuthPage.login;
  @override
  void dispose() {
    registration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (page) {
        _AuthPage.login => LoginPage(
            api: widget.api,
            onLogin: widget.onLogin,
            onAuthenticated: widget.onAuthenticated,
            onRegister: () => setState(() => page = _AuthPage.register)),
        _AuthPage.register => RegistrationPage(
            controller: registration,
            onVerification: (_) => setState(() => page = _AuthPage.verify),
            onBack: () => setState(() => page = _AuthPage.login)),
        _AuthPage.verify => VerificationPage(
            controller: registration,
            onChangeEmail: () => setState(() => page = _AuthPage.register),
            onCompleted: () => setState(() => page = _AuthPage.login))
      };
}
