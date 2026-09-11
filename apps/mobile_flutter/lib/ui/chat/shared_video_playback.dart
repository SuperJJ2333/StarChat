import 'package:flutter/foundation.dart';

import '../../core/screen_on_lease_coordinator.dart';
import 'video_playback_arbiter.dart';
import 'video_playback_lease_coordinator.dart';

/// Process-wide playback services shared by every local video surface.
///
/// Pages keep their own lifecycle and activation revisions. They use this
/// singleton only to serialize native playback and to hold one shared screen-on
/// demand while any permitted player is active.
final class SharedVideoPlayback {
  static final arbiter = VideoPlaybackArbiter();
  static final _screenOnDemand = ScreenOnDemand(screenOnLeaseCoordinator);
  static final wakelockCoordinator =
      VideoPlaybackLeaseCoordinator(_screenOnDemand.setEnabled);

  @visibleForTesting
  static Future<void> get wakelockSettled => wakelockCoordinator.settled;
}
