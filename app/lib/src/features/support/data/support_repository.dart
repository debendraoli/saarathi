import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/provider_retry.dart';
import '../domain/models.dart';

class SupportRepository {
  SupportRepository(this._api);
  final ApiClient _api;

  Future<List<SupportMessage>> myThread() async {
    final res = await _api.get('/v1/support/messages') as List;
    return res
        .cast<Map<String, dynamic>>()
        .map(SupportMessage.fromJson)
        .toList();
  }

  Future<SupportMessage> send(String body,
      {String? tripId, String? orderId}) async {
    final res = await _api.post(
      '/v1/support/messages',
      body: {
        'body': body,
        if (tripId != null) 'trip_id': tripId,
        if (orderId != null) 'order_id': orderId,
      },
    ) as Map<String, dynamic>;
    return SupportMessage.fromJson(res);
  }
}

final supportRepositoryProvider = Provider<SupportRepository>((ref) {
  return SupportRepository(ref.watch(apiClientProvider));
});

final supportThreadProvider =
    FutureProvider.autoDispose<List<SupportMessage>>((ref) {
  return ref.watch(supportRepositoryProvider).myThread();
}, retry: shortNetworkRetry);
