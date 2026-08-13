import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

final class WeChatListTile extends StatelessWidget {
  const WeChatListTile({super.key,required this.title,this.subtitle,this.leading,this.trailing,this.onTap});
  final Widget title; final Widget? subtitle,leading,trailing; final VoidCallback? onTap;
  @override Widget build(BuildContext context)=>Container(constraints:const BoxConstraints(minHeight:56),color:CupertinoTheme.of(context).barBackgroundColor,padding:const EdgeInsets.symmetric(horizontal:WeChatSpacing.lg),child:CupertinoListTile(padding:EdgeInsets.zero,title:title,subtitle:subtitle,leading:leading,trailing:trailing,onTap:onTap));
}
