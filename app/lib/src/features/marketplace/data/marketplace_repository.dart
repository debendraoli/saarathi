import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';
import '../domain/models.dart';

class MarketplaceRepository {
  MarketplaceRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;

  Future<List<Merchant>> merchants(String vertical, LatLng? at) =>
      cacheThroughList(
        prefs: _prefs,
        key: 'cache.merchants.$vertical',
        fetch: () => _api.get(
          '/v1/merchants',
          query: {
            'vertical': vertical,
            if (at != null) 'lat': at.latitude,
            if (at != null) 'lng': at.longitude,
          },
        ),
        parse: Merchant.fromJson,
      );

  Future<(Merchant, List<MenuItem>)> detail(String id) async {
    final res = await _api.get('/v1/merchants/$id') as Map<String, dynamic>;
    final merchant = Merchant.fromJson(res['merchant'] as Map<String, dynamic>);
    final items = (res['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(MenuItem.fromJson)
        .toList();
    return (merchant, items);
  }

  Future<CustomerOrder> placeOrder({
    required String merchantId,
    required Map<String, int> lines, // menu_item_id -> qty
    required LatLng delivery,
    String? note,
    String paymentMethod = 'cash',
  }) async {
    final res = await _api.post(
      '/v1/orders',
      body: {
        'merchant_id': merchantId,
        'items': [
          for (final e in lines.entries)
            {'menu_item_id': e.key, 'qty': e.value},
        ],
        'delivery': {'lat': delivery.latitude, 'lng': delivery.longitude},
        if (note != null && note.isNotEmpty) 'delivery_note': note,
        'payment_method': paymentMethod,
      },
    ) as Map<String, dynamic>;
    return _parseOrder(res);
  }

  Future<List<CustomerOrder>> myOrders() => cacheThroughList(
        prefs: _prefs,
        key: 'cache.orders',
        fetch: () => _api.get('/v1/orders'),
        parse: (j) => CustomerOrder.fromJson(j),
      );

  Future<CustomerOrder> order(String id) async {
    final res = await _api.get('/v1/orders/$id') as Map<String, dynamic>;
    return _parseOrder(res);
  }

  CustomerOrder _parseOrder(Map<String, dynamic> res) {
    final order = res['order'] as Map<String, dynamic>;
    final items = (res['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(OrderItem.fromJson)
        .toList();
    return CustomerOrder.fromJson(order, items: items);
  }
}

final marketplaceRepositoryProvider = Provider<MarketplaceRepository>((ref) {
  return MarketplaceRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

final merchantsProvider =
    FutureProvider.autoDispose.family<List<Merchant>, String>((ref, vertical) {
  return ref.watch(marketplaceRepositoryProvider).merchants(vertical, null);
});

final merchantDetailProvider = FutureProvider.autoDispose
    .family<(Merchant, List<MenuItem>), String>((ref, id) {
  return ref.watch(marketplaceRepositoryProvider).detail(id);
});

final orderProvider = StreamProvider.autoDispose.family<CustomerOrder, String>((
  ref,
  id,
) async* {
  final repo = ref.watch(marketplaceRepositoryProvider);
  while (true) {
    final order = await repo.order(id);
    yield order;
    if (!order.isActive) break;
    await Future<void>.delayed(const Duration(seconds: 4));
  }
});
