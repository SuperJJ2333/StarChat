import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import '../../features/matrix/gallery_video_preview.dart';
import '../../features/matrix/video_transcode.dart';
import '../motion/motion_page_route.dart';
import '../foundation/wechat_tokens.dart';
import 'moment_media_cache.dart';

/// Explicit playback keeps the feed light and uses the existing native player,
/// playback arbiter, screen-on lease and account media object cache.
final class MomentVideoTile extends StatefulWidget {
  const MomentVideoTile(
      {super.key,
      required this.url,
      this.cacheKey,
      this.accountKey,
      this.trustedOrigin});
  final String url;
  final String? cacheKey, accountKey, trustedOrigin;

  @override
  State<MomentVideoTile> createState() => _MomentVideoTileState();
}

final class _MomentVideoTileState extends State<MomentVideoTile> {
  Uint8List? _poster;
  int _posterRevision = 0;

  @override
  void initState() {
    super.initState();
    _loadPoster();
  }

  @override
  void didUpdateWidget(MomentVideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.accountKey != widget.accountKey ||
        oldWidget.trustedOrigin != widget.trustedOrigin) {
      _poster = null;
      _loadPoster();
    }
  }

  void _loadPoster() {
    final revision = ++_posterRevision;
    if (widget.cacheKey == null || widget.accountKey == null) return;
    unawaited(MomentMediaCache.cachedVideoPoster(widget.url,
            cacheKey: widget.cacheKey,
            accountKey: widget.accountKey,
            trustedOrigin: widget.trustedOrigin)
        .then((bytes) {
      if (mounted && revision == _posterRevision && bytes != null) {
        setState(() => _poster = bytes);
      }
    }).catchError((Object _) {
      // An evicted or account-cleared poster leaves the play entry available.
    }));
  }

  @override
  Widget build(BuildContext context) => CupertinoButton(
        key: const Key('moment-video-play'),
        color: WeChatColors.resolve(context, WeChatColors.lightSurface),
        padding: EdgeInsets.zero,
        onPressed: () {
          var retry = false;
          Navigator.of(context, rootNavigator: true).push(
            MotionPageRoute(
                builder: (_) => GalleryVideoPreviewPage(
                      viewerOnly: true,
                      thumbnailBytes: _poster ?? Uint8List(0),
                      duration: null,
                      selected: false,
                      onToggle: () {},
                      loadRendition: () async {
                        final refresh = retry;
                        retry = true;
                        return VideoRendition(
                          file: await MomentMediaCache.videoFile(widget.url,
                              refresh: refresh,
                              cacheKey: widget.cacheKey,
                              accountKey: widget.accountKey,
                              trustedOrigin: widget.trustedOrigin),
                          usedCompressed: false,
                        );
                      },
                    )),
          );
        },
        child: SizedBox(
          width: 160,
          height: 112,
          child: Stack(fit: StackFit.expand, children: [
            if (_poster case final bytes?)
              Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 480),
            Center(
                child: Icon(CupertinoIcons.play_circle,
                    size: 40,
                    color: _poster == null
                        ? WeChatColors.resolveTextPrimary(context)
                        : CupertinoColors.white)),
            if (_poster == null)
              const Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('播放视频'))),
          ]),
        ),
      );
}
