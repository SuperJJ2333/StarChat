import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import '../../features/matrix/gallery_video_preview.dart';
import '../../features/matrix/video_transcode.dart';
import '../motion/motion_page_route.dart';
import '../foundation/wechat_tokens.dart';
import 'moment_media_cache.dart';

/// Explicit playback keeps the feed light and uses the existing native player,
/// playback arbiter, screen-on lease and account media object cache.
final class MomentVideoTile extends StatelessWidget {
  const MomentVideoTile(
      {super.key,
      required this.url,
      this.cacheKey,
      this.accountKey,
      this.trustedOrigin});
  final String url;
  final String? cacheKey, accountKey, trustedOrigin;

  @override
  Widget build(BuildContext context) => CupertinoButton(
        key: const Key('moment-video-play'),
        color: WeChatColors.resolve(context, WeChatColors.lightSurface),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        onPressed: () {
          var retry = false;
          Navigator.of(context, rootNavigator: true).push(
            MotionPageRoute(
                builder: (_) => GalleryVideoPreviewPage(
                      viewerOnly: true,
                      thumbnailBytes: Uint8List(0),
                      duration: null,
                      selected: false,
                      onToggle: () {},
                      loadRendition: () async {
                        final refresh = retry;
                        retry = true;
                        return VideoRendition(
                          file: await MomentMediaCache.videoFile(url,
                              refresh: refresh,
                              cacheKey: cacheKey,
                              accountKey: accountKey,
                              trustedOrigin: trustedOrigin),
                          usedCompressed: false,
                        );
                      },
                    )),
          );
        },
        child: const Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(CupertinoIcons.play_circle, size: 40),
          SizedBox(height: 6),
          Text('播放视频'),
        ]),
      );
}
