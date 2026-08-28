import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/provider_retry.dart';
import '../domain/models.dart';

class CampaignsRepository {
  CampaignsRepository(this._api);
  final ApiClient _api;

  /// Active, in-window rider offers — purely for display, no code needed;
  /// the best-matching one is auto-applied server-side at ride checkout.
  Future<List<Offer>> activeOffers() async {
    final res = await _api.get('/v1/campaigns/active') as List;
    return res.cast<Map<String, dynamic>>().map(Offer.fromJson).toList();
  }
}

final campaignsRepositoryProvider = Provider<CampaignsRepository>((ref) {
  return CampaignsRepository(ref.watch(apiClientProvider));
});

final activeOffersProvider = FutureProvider.autoDispose<List<Offer>>((ref) {
  return ref.watch(campaignsRepositoryProvider).activeOffers();
}, retry: shortNetworkRetry);
