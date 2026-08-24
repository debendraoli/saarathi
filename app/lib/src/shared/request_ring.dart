import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:vibration/vibration.dart';

/// Plays the device's actual system ringtone (via Android's RingtoneManager/
/// iOS's system sound APIs — no bundled audio asset, respects the user's own
/// ringtone/volume settings) *and* vibrates, simultaneously and
/// unconditionally, when a driver offer or merchant order arrives. Deliberately
/// more insistent than [NotificationService]'s one-shot notification chime —
/// these are short-lived, time-sensitive requests the recipient needs to
/// actually notice.
///
/// The sound stays on Android's ring stream, which the OS mutes in
/// silent/vibrate mode — that muting is intentional (a driver who's silenced
/// their phone shouldn't get blasted). The vibration is the actual signal
/// that must never be silent: it fires every time, regardless of ringer
/// mode, so a silenced phone still degrades to "buzzing", not "nothing".
abstract final class RequestRing {
  static final _player = FlutterRingtonePlayer();
  static Timer? _autoStop;

  /// Repeats until [stop] cancels it — a long pattern, not a single buzz.
  static const _vibratePattern = [0, 600, 400];

  /// Starts (or restarts) the ring + vibration, looping until [stop] is
  /// called or [maxDuration] elapses, whichever comes first — a safety net
  /// in case a caller's stop path is missed.
  static Future<void> play(
      {Duration maxDuration = const Duration(seconds: 6)}) async {
    _autoStop?.cancel();
    try {
      await _player.playRingtone(looping: true);
    } catch (e, st) {
      developer.log('RequestRing: playRingtone failed',
          error: e, stackTrace: st);
    }
    try {
      if (await Vibration.hasVibrator()) {
        await Vibration.vibrate(pattern: _vibratePattern, repeat: 0);
      }
    } catch (e, st) {
      developer.log('RequestRing: vibrate failed', error: e, stackTrace: st);
    }
    _autoStop = Timer(maxDuration, stop);
  }

  static Future<void> stop() async {
    _autoStop?.cancel();
    _autoStop = null;
    try {
      await _player.stop();
    } catch (e, st) {
      developer.log('RequestRing: stop ringtone failed',
          error: e, stackTrace: st);
    }
    try {
      await Vibration.cancel();
    } catch (e, st) {
      developer.log('RequestRing: cancel vibration failed',
          error: e, stackTrace: st);
    }
  }
}
