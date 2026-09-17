/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'package:matrix/matrix.dart';

/// ChatFlow (Task I): single-owner audio route contract.
///
/// Historically `CallSession.addLocalStream()` set the OS speakerphone state
/// from the call type while the host application also called
/// `Helper.setSpeakerphoneOn()`. Two owners writing the same output route
/// produced route thrash (speaker flip-flop, echo on some devices).
///
/// A host application that wants to own output routing installs an
/// [AudioRouteSink] on `VoIP`. The SDK then only reports *events* and never
/// touches the route itself; the sink decides the policy.
abstract class AudioRouteSink {
  /// A local user-media stream (microphone/camera) was attached to the call.
  ///
  /// Implementations should re-assert their own route preference here rather
  /// than deriving one from [type].
  void onLocalUserMediaStreamAdded(CallType type);
}
