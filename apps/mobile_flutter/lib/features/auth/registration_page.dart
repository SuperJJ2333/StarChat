import 'package:flutter/cupertino.dart';
import '../../ui/components/immersive_auth_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import 'registration_controller.dart';

final class RegistrationPage extends StatefulWidget {
  const RegistrationPage({super.key, required this.controller, required this.onVerification, required this.onBack});
  final RegistrationController controller;
  final ValueChanged<String> onVerification;
  final VoidCallback onBack;
  @override State<RegistrationPage> createState() => _RegistrationPageState();
}
final class _RegistrationPageState extends State<RegistrationPage> {
  final username=TextEditingController(),email=TextEditingController(),password=TextEditingController(),invitation=TextEditingController();
  @override void initState(){super.initState();widget.controller.addListener(_changed);}
  @override void dispose(){widget.controller.removeListener(_changed);username.dispose();email.dispose();password.dispose();invitation.dispose();super.dispose();}
  void _changed(){if(mounted)setState((){});}
  Future<void> submit() async {if(invitation.text.trim().isEmpty)return;final ok=await widget.controller.register(username:username.text.trim(),email:email.text.trim(),password:password.text,invitationCode:invitation.text.trim());if(ok&&mounted)widget.onVerification(widget.controller.state.registrationSession!);}
  @override Widget build(BuildContext context){final loading=widget.controller.state.status==RegistrationFlowStatus.submitting;return ImmersiveAuthScaffold(child:ListView(padding:const EdgeInsets.all(24),children:[const SizedBox(height:32),const Text('创建六合通账号',style:TextStyle(fontSize:28,fontWeight:FontWeight.w600)),const SizedBox(height:24),CupertinoTextField(controller:username,placeholder:'用户名'),const SizedBox(height:12),CupertinoTextField(controller:email,placeholder:'邮箱',keyboardType:TextInputType.emailAddress),const SizedBox(height:12),CupertinoTextField(controller:password,placeholder:'密码',obscureText:true),const SizedBox(height:12),CupertinoTextField(controller:invitation,placeholder:'邀请码（必填）',onChanged:(_)=>setState((){})),for(final error in widget.controller.state.fieldErrors.values)Padding(padding:const EdgeInsets.only(top:8),child:Text(error,style:const TextStyle(color:CupertinoColors.systemRed))),if(widget.controller.state.message!=null)Text(widget.controller.state.message!,style:const TextStyle(color:CupertinoColors.systemRed)),const SizedBox(height:20),ModernActionButton(icon:CupertinoIcons.person_add,label:'注册',loading:loading,onPressed:loading||invitation.text.trim().isEmpty?null:submit),const SizedBox(height:8),ModernActionButton(icon:CupertinoIcons.back,label:'返回登录',kind:ModernActionKind.secondary,onPressed:widget.onBack)]));}
}
