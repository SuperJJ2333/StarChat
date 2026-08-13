import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

final class WeChatPrimaryButton extends StatelessWidget {
  const WeChatPrimaryButton({super.key, required this.label, required this.onPressed, this.loading=false});
  final String label; final VoidCallback? onPressed; final bool loading;
  @override Widget build(BuildContext context) => SizedBox(height:48, width:double.infinity, child:CupertinoButton(color:WeChatColors.brandPrimary, disabledColor:WeChatColors.brandPrimary.withValues(alpha:.45), borderRadius:BorderRadius.circular(WeChatRadius.control), onPressed:loading?null:onPressed, child:Row(mainAxisSize:MainAxisSize.min,children:[if(loading)...[const CupertinoActivityIndicator(color:CupertinoColors.white),const SizedBox(width:WeChatSpacing.sm)],Text(label,style:const TextStyle(color:CupertinoColors.white,fontSize:WeChatTypography.callout))])));
}
