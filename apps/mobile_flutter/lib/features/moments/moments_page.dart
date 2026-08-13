import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/moments/wechat_moment_tile.dart';
final class MomentsPage extends StatefulWidget{const MomentsPage({super.key,required this.api});final BusinessApiClient api;@override State<MomentsPage> createState()=>_MomentsPageState();}
final class _MomentsPageState extends State<MomentsPage>{String mode='recommended';
 @override Widget build(BuildContext context)=>CupertinoPageScaffold(
  navigationBar:CupertinoNavigationBar(middle:const Text('朋友圈'),trailing:CupertinoButton(padding:EdgeInsets.zero,onPressed:()=>Navigator.push(context,CupertinoPageRoute(builder:(_)=>MomentComposerPage(api:widget.api))),child:const Icon(CupertinoIcons.camera))),
  child:SafeArea(child:FutureBuilder<Map<String,dynamic>>(future:widget.api.momentsFeed(mode:mode),builder:(_,snapshot){final items=(snapshot.data?['items'] as List?)??const[];return ListView(children:[
   SizedBox(height:200,child:Container(color:const Color(0xff4c4c4c),alignment:Alignment.bottomRight,padding:const EdgeInsets.all(16),child:const Text('六合通朋友圈',style:TextStyle(color:CupertinoColors.white,fontSize:22)))),
   CupertinoSlidingSegmentedControl<String>(groupValue:mode,children:const{'recommended':Text('推荐'),'latest':Text('最新')},onValueChanged:(v)=>setState(()=>mode=v!)),
   for(final m in items) WeChatMomentTile(author:m['author_id'].toString(),text:m['text'].toString(),images:List<String>.from(m['image_urls']??const[]),onLike:()=>widget.api.likeMoment(m['id'].toString())),
  ]);})),
 );
}
final class MomentComposerPage extends StatefulWidget{const MomentComposerPage({super.key,required this.api});final BusinessApiClient api;@override State<MomentComposerPage> createState()=>_ComposerState();}
final class _ComposerState extends State<MomentComposerPage>{final text=TextEditingController();String visibility='PUBLIC';@override void dispose(){text.dispose();super.dispose();}@override Widget build(BuildContext context)=>CupertinoPageScaffold(navigationBar:CupertinoNavigationBar(middle:const Text('发表'),trailing:CupertinoButton(onPressed:()async{await widget.api.publishMoment(text:text.text,visibility:visibility);if(context.mounted)Navigator.pop(context);},child:const Text('发表'))),child:SafeArea(child:ListView(padding:const EdgeInsets.all(16),children:[CupertinoTextField(controller:text,minLines:5,maxLines:10,placeholder:'这一刻的想法…'),const SizedBox(height:16),CupertinoSlidingSegmentedControl<String>(groupValue:visibility,children:const{'PUBLIC':Text('公开'),'FRIENDS':Text('好友'),'SELF':Text('私密')},onValueChanged:(v)=>setState(()=>visibility=v!)),const SizedBox(height:16),const Text('首版支持最多9张图片，不支持视频。公开内容会接受平台审核。')])));}
