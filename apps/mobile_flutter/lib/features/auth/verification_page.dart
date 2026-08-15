import 'package:flutter/cupertino.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import 'registration_controller.dart';

final class VerificationPage extends StatefulWidget {
  const VerificationPage({super.key, required this.controller, required this.onChangeEmail, required this.onCompleted});
  final RegistrationController controller;final VoidCallback onChangeEmail,onCompleted;
  @override State<VerificationPage> createState()=>_VerificationPageState();
}
final class _VerificationPageState extends State<VerificationPage>{final code=TextEditingController();@override void initState(){super.initState();widget.controller.addListener(_change);}@override void dispose(){widget.controller.removeListener(_change);code.dispose();super.dispose();}void _change(){if(mounted)setState((){});}Future<void> verify()async{await widget.controller.verifyCode(code.text);if(await widget.controller.pollUntilActive()&&mounted)widget.onCompleted();}
  @override Widget build(BuildContext context){final state=widget.controller.state;return ImmersiveAuthScaffold(child:ListView(padding:const EdgeInsets.all(24),children:[const SizedBox(height:48),const Text('验证邮箱',style:TextStyle(fontSize:28,fontWeight:FontWeight.w600)),const SizedBox(height:12),const Text('请输入邮件中的 6 位验证码，或返回应用查看验证链接结果。'),const SizedBox(height:20),CupertinoTextField(controller:code,placeholder:'6 位验证码',keyboardType:TextInputType.number,maxLength:6),const SizedBox(height:12),ModernActionButton(icon:CupertinoIcons.check_mark_circled,label:'验证并继续',onPressed:verify),const SizedBox(height:8),ModernActionButton(icon:CupertinoIcons.mail,label:state.resendAfterSeconds>0?'${state.resendAfterSeconds} 秒后重发':'重新发送邮件',kind:ModernActionKind.secondary,onPressed:state.resendAfterSeconds>0?null:widget.controller.resend),ModernActionButton(icon:CupertinoIcons.pencil,label:'修改邮箱',kind:ModernActionKind.secondary,onPressed:widget.onChangeEmail),const SizedBox(height:12),Text(state.status==RegistrationFlowStatus.provisioning?'正在创建加密通信账号…':state.status==RegistrationFlowStatus.completed?'账号已就绪':'等待邮箱验证',key:const Key('registration-status'))]));}
}
