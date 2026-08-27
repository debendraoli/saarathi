import 'package:flutter_tts/flutter_tts.dart';

/// Speaks turn-by-turn instructions during navigation — a thin wrapper so
/// the nav screen doesn't deal with `FlutterTts`'s own setup directly.
/// A single shared instance (not per-screen) since there's only ever one
/// active navigation session at a time and this avoids re-initializing the
/// platform TTS engine on every screen mount.
class TurnAnnouncer {
  TurnAnnouncer._();
  static final TurnAnnouncer instance = TurnAnnouncer._();

  final FlutterTts _tts = FlutterTts();
  String? _language;

  /// Sets the voice language — 'en-US' or 'ne-NP' for the app's 'en'/'ne'
  /// locale codes. Not every device ships a Nepali TTS voice; if the engine
  /// doesn't recognise it, this falls back to English rather than leaving
  /// navigation silent because one particular voice is missing.
  Future<void> setLanguage(String appLanguageCode) async {
    final tag = appLanguageCode == 'ne' ? 'ne-NP' : 'en-US';
    if (_language == tag) return;
    bool available;
    try {
      final result = await _tts.isLanguageAvailable(tag);
      available = result == true || result == 1;
    } catch (_) {
      available = false;
    }
    final effective = available ? tag : 'en-US';
    if (_language == effective) return;
    await _tts.setLanguage(effective);
    _language = effective;
  }

  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();
}
