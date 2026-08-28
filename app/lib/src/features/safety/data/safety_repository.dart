import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/provider_retry.dart';
import '../domain/models.dart';

class SafetyRepository {
  SafetyRepository(this._api);
  final ApiClient _api;

  Future<List<TrustedContact>> trustedContacts() async {
    final res = await _api.get('/v1/trusted-contacts') as List;
    return res.cast<Map<String, dynamic>>().map(TrustedContact.fromJson).toList();
  }

  Future<TrustedContact> addTrustedContact(String name, String phone) async {
    final res = await _api.post(
      '/v1/trusted-contacts',
      body: {'name': name, 'phone': phone},
    ) as Map<String, dynamic>;
    return TrustedContact.fromJson(res);
  }

  Future<void> removeTrustedContact(String id) =>
      _api.delete('/v1/trusted-contacts/$id');

  Future<RideIndex> rideIndex() async {
    final res = await _api.get('/v1/ride-index') as Map<String, dynamic>;
    return RideIndex.fromJson(res);
  }
}

final safetyRepositoryProvider = Provider<SafetyRepository>((ref) {
  return SafetyRepository(ref.watch(apiClientProvider));
});

final trustedContactsProvider =
    FutureProvider.autoDispose<List<TrustedContact>>((ref) {
  return ref.watch(safetyRepositoryProvider).trustedContacts();
}, retry: shortNetworkRetry);

final rideIndexProvider = FutureProvider.autoDispose<RideIndex>((ref) {
  return ref.watch(safetyRepositoryProvider).rideIndex();
}, retry: shortNetworkRetry);
