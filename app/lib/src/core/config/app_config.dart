import 'package:flutter/foundation.dart';

/// App-wide configuration. The API base can be overridden at build/run time:
///   flutter run --dart-define=SAARATHI_API_BASE=http://localhost:8080
class AppConfig {
  const AppConfig._();

  static const String _apiOverride =
      String.fromEnvironment('SAARATHI_API_BASE', defaultValue: '');

  /// Single north-south front door (the Traefik gateway). On the Android
  /// emulator the host machine is reachable at 10.0.2.2, not localhost.
  static String get apiBase {
    if (_apiOverride.isNotEmpty) return _apiOverride;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8080';
    }
    return 'http://localhost:8080';
  }

  /// WebSocket base derived from the API base (http→ws, https→wss).
  static String get wsBase =>
      apiBase.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');

  static const String deepLinkScheme = 'saarathi';

  /// Default map tiles. Swap to your self-hosted OSM tile server in production
  /// (e.g. https://tiles.saarathi.np/{z}/{x}/{y}.png) — Nepal/cost reasons.
  static const String tileUrlTemplate =
      String.fromEnvironment('SAARATHI_TILE_URL', defaultValue: '');

  /// Dang district centre (Ghorahi) — used before we have a GPS fix.
  static const double defaultLat = 28.033;
  static const double defaultLng = 82.484;
}
