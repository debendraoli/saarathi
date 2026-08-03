import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';

/// Fetches ICE servers (STUN + short-lived TURN credentials) from the backend,
/// which mints them from our self-hosted Coturn. Falls back to the local
/// config when the call can't be made (offline / older backend).
class RtcRepository {
  RtcRepository(this._api);
  final ApiClient _api;

  Future<List<Map<String, dynamic>>> iceServers() async {
    try {
      final res = await _api.get('/v1/rtc/ice') as Map<String, dynamic>;
      final servers =
          (res['ice_servers'] as List?)?.cast<Map<String, dynamic>>();
      if (servers != null && servers.isNotEmpty) return servers;
    } catch (_) {/* fall back below */}
    return AppConfig.iceServers;
  }
}

final rtcRepositoryProvider = Provider<RtcRepository>((ref) {
  return RtcRepository(ref.watch(apiClientProvider));
});
