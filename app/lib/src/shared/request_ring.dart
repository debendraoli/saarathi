import 'dart:async';

import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

/// Plays the device's actual system ringtone (via Android's RingtoneManager/
/// iOS's system sound APIs — no bundled audio asset, respects the user's own
/// ringtone/volume settings) when a driver offer or merchant order arrives.
/// Deliberately more insistent than [NotificationService]'s one-shot
/// notification chime — these are short-lived, time-sensitive requests the
/// recipient needs to actually notice.
abstract final class RequestRing {
  static final _player = FlutterRingtonePlayer();
  static Timer? _autoStop;

  /// Starts (or restarts) the ring, looping until [stop] is called or
  /// [maxDuration] elapses, whichever comes first — a safety net in case a
  /// caller's stop path is missed.
  static Future<void> play(
      {Duration maxDuration = const Duration(seconds: 6)}) async {
    _autoStop?.cancel();
    await _player.playRingtone(looping: true);
    _autoStop = Timer(maxDuration, stop);
  }

  static Future<void> stop() async {
    _autoStop?.cancel();
    _autoStop = null;
    await _player.stop();
  }
}
