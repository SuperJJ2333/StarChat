import 'package:flutter/cupertino.dart';

final class WeChatPageScaffold extends StatelessWidget {
  const WeChatPageScaffold({super.key,required this.title,required this.child,this.trailing});
  final String title; final Widget child; final Widget? trailing;
  @override Widget build(BuildContext context)=>CupertinoPageScaffold(navigationBar:CupertinoNavigationBar(middle:Text(title),trailing:trailing),child:SafeArea(child:child));
}
