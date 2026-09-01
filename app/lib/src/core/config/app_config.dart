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
  static String get wsBase => apiBase
      .replaceFirst('https://', 'wss://')
      .replaceFirst('http://', 'ws://');

  static const String deepLinkScheme = 'saarathi';

  /// Self-hosted Coturn (TURN/STUN) for WebRTC NAT traversal. Configure at build:
  ///   --dart-define=SAARATHI_TURN_URL=turn:turn.saarathi.np:3478
  ///   --dart-define=SAARATHI_TURN_USER=... --dart-define=SAARATHI_TURN_PASS=...
  static const String turnUrl =
      String.fromEnvironment('SAARATHI_TURN_URL', defaultValue: '');
  static const String turnUser =
      String.fromEnvironment('SAARATHI_TURN_USER', defaultValue: '');
  static const String turnPass =
      String.fromEnvironment('SAARATHI_TURN_PASS', defaultValue: '');

  /// ICE servers: a public STUN plus our TURN relay when configured.
  static List<Map<String, dynamic>> get iceServers => [
        {'urls': 'stun:stun.l.google.com:19302'},
        if (turnUrl.isNotEmpty)
          {'urls': turnUrl, 'username': turnUser, 'credential': turnPass},
      ];

  /// Self-hosted Martin vector-tile server base (no trailing slash). MapView
  /// (see its doc comment) builds the full style from this at runtime: tiles
  /// at `$martinBaseUrl/nepal/{z}/{x}/{y}`, glyphs at
  /// `$martinBaseUrl/font/{fontstack}/{range}`. In production this is the
  /// `api.<domain>` IngressRoute's `/tiles` prefix (martin-deployment.yaml) —
  /// Martin itself has no public port; Traefik strips the prefix before
  /// forwarding. Configure at build:
  ///   --dart-define=SAARATHI_MARTIN_URL=http://localhost:8092   (docker-compose)
  ///   --dart-define=SAARATHI_MARTIN_URL=https://api.saarathi.example/tiles  (k8s)
  /// Empty falls back to MapLibre's public demo style/tiles — enough to
  /// render *something* before a Martin deployment is configured, same
  /// graceful-degradation spirit as the old raster tile URL had.
  static const String martinBaseUrl =
      String.fromEnvironment('SAARATHI_MARTIN_URL', defaultValue: '');

  /// Dang district centre (Ghorahi) — used before we have a GPS fix.
  static const double defaultLat = 28.033;
  static const double defaultLng = 82.484;
}
