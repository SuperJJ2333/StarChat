import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';
import 'package:liuhetong_mobile/features/auth/registration_page.dart';
import 'package:liuhetong_mobile/features/auth/verification_page.dart';
import 'package:liuhetong_mobile/ui/components/modern_action_button.dart';

final class PageGateway implements RegistrationGateway {
  @override Future<bool> validateInvitation(String invitationCode) async => true;
  @override Future<RegistrationReceipt> register({required String username,required String email,required String password,required String invitationCode}) async=>const RegistrationReceipt(registrationSession:'session',status:'PENDING_EMAIL',resendAfterSeconds:60);
  @override Future<int> resendVerification(String registrationSession) async=>60;
  @override Future<RegistrationStatusReceipt> registrationStatus(String registrationSession)async=>const RegistrationStatusReceipt(status:'ACTIVE',resendAfterSeconds:0);
  @override Future<void> verifyEmail({required String registrationSession,String? code,String? token})async{}
}

void main(){
  testWidgets('login registration and verification share the immersive background',(tester)async{
    final api=BusinessApiClient(baseUri:Uri.parse('http://localhost'),sessionStore:SecureSessionStore());
    final controller=RegistrationController(gateway:PageGateway());
    final pages=<Widget>[LoginPage(api:api,onLogin:(_,__)async{}),RegistrationPage(controller:controller,onVerification:(_){},onBack:(){}),VerificationPage(controller:controller,onChangeEmail:(){},onCompleted:(){})];
    for(final page in pages){await tester.pumpWidget(CupertinoApp(home:page));expect(find.byWidgetPredicate((widget)=>widget is Image&&widget.image is AssetImage&&(widget.image as AssetImage).assetName=='assets/landing.png'),findsOneWidget);}
  });
  testWidgets('registration contains all required fields and invitation gates submit',(tester)async{
    final controller=RegistrationController(gateway:PageGateway());
    await tester.pumpWidget(CupertinoApp(home:RegistrationPage(controller:controller,onVerification:(_){},onBack:(){})));
    expect(find.byType(CupertinoTextField),findsNWidgets(4));
    expect(find.text('邀请码（必填）'),findsOneWidget);
    expect(tester.widget<ModernActionButton>(find.widgetWithText(ModernActionButton,'注册')).onPressed,isNull);
    await tester.enterText(find.byType(CupertinoTextField).last,'INVITE');await tester.pump();
    expect(tester.widget<ModernActionButton>(find.widgetWithText(ModernActionButton,'注册')).onPressed,isNotNull);
  });
  testWidgets('verification exposes code link result resend change email and status',(tester)async{
    final controller=RegistrationController(gateway:PageGateway());
    await controller.register(username:'alice',email:'a@x.test',password:'long-password',invitationCode:'INVITE');
    await tester.pumpWidget(CupertinoApp(home:VerificationPage(controller:controller,onChangeEmail:(){},onCompleted:(){})));
    expect(find.textContaining('验证链接结果'),findsOneWidget);expect(find.textContaining('秒后重发'),findsOneWidget);expect(find.text('修改邮箱'),findsOneWidget);expect(find.byKey(const Key('registration-status')),findsOneWidget);
  });
  testWidgets('keyboard inset moves form but not landing background',(tester)async{
    final api=BusinessApiClient(baseUri:Uri.parse('http://localhost'),sessionStore:SecureSessionStore());
    await tester.pumpWidget(MediaQuery(data:const MediaQueryData(viewInsets:EdgeInsets.zero),child:CupertinoApp(home:LoginPage(api:api,onLogin:(_,__)async{}))));
    final before=tester.getTopLeft(find.byType(Image).first);
    await tester.pumpWidget(MediaQuery(data:const MediaQueryData(viewInsets:EdgeInsets.only(bottom:300)),child:CupertinoApp(home:LoginPage(api:api,onLogin:(_,__)async{}))));
    expect(tester.getTopLeft(find.byType(Image).first),before);
  });
}
