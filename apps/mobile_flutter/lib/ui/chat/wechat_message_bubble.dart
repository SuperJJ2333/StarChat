import 'package:flutter/cupertino.dart';
import '../foundation/wechat_tokens.dart';

enum MessageDirection { incoming, outgoing }
enum MessageDeliveryState { sending, sent, failed }

final class WeChatMessageBubble extends StatelessWidget {
  const WeChatMessageBubble({super.key,required this.direction,required this.content,this.state=MessageDeliveryState.sent,this.onRetry});
  final MessageDirection direction; final Widget content; final MessageDeliveryState state; final VoidCallback? onRetry;
  @override Widget build(BuildContext context){final outgoing=direction==MessageDirection.outgoing; return Align(alignment:outgoing?Alignment.centerRight:Alignment.centerLeft,child:FractionallySizedBox(widthFactor:.72,child:Row(mainAxisAlignment:outgoing?MainAxisAlignment.end:MainAxisAlignment.start,children:[if(state==MessageDeliveryState.failed)CupertinoButton(padding:const EdgeInsets.all(4),onPressed:onRetry,child:const Icon(CupertinoIcons.exclamationmark_circle_fill,color:WeChatColors.danger)),Flexible(child:DecoratedBox(decoration:BoxDecoration(color:outgoing?WeChatColors.bubbleOutgoing:CupertinoTheme.of(context).barBackgroundColor,borderRadius:BorderRadius.circular(WeChatRadius.bubble)),child:Padding(padding:const EdgeInsets.symmetric(horizontal:12,vertical:9),child:content))),if(state==MessageDeliveryState.sending)const Padding(padding:EdgeInsets.all(4),child:CupertinoActivityIndicator(radius:7))])));}
}
