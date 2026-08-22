import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/api_client.dart';
import '../../marketplace/domain/models.dart';

/// Merchant-owner surface: the store(s) a user owns, their menu, and the live
/// order queue. Backed by the /v1/merchant/* endpoints (owner- or staff-scoped).
class MerchantRepository {
  MerchantRepository(this._api);
  final ApiClient _api;

  /// Self-service store registration. Returns the new merchant id.
  Future<String> apply({
    required String name,
    required String vertical,
    required LatLng point,
    String? address,
    String? phone,
    String? panVat,
  }) async {
    final res = await _api.post('/v1/merchant/apply', body: {
      'name': name,
      'vertical': vertical,
      'lat': point.latitude,
      'lng': point.longitude,
      if (address != null && address.isNotEmpty) 'address': address,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (panVat != null && panVat.isNotEmpty) 'pan_vat': panVat,
    }) as Map<String, dynamic>;
    return res['id'] as String;
  }

  Future<List<Merchant>> myMerchants() async {
    final res = await _api.get('/v1/merchant/merchants') as List;
    return res.cast<Map<String, dynamic>>().map(Merchant.fromJson).toList();
  }

  Future<List<MenuItem>> menu(String merchantId) async {
    final res =
        await _api.get('/v1/merchant/merchants/$merchantId/menu') as List;
    return res.cast<Map<String, dynamic>>().map(MenuItem.fromJson).toList();
  }

  /// Returns the new item's id, so a just-picked photo can be uploaded right
  /// after (the create call itself is plain JSON, not multipart).
  Future<String> addItem({
    required String merchantId,
    required String name,
    required double price,
    String? category,
    String? description,
  }) async {
    final res = await _api.post('/v1/merchant/menu', body: {
      'merchant_id': merchantId,
      'name': name,
      'price': price.toStringAsFixed(2),
      if (category != null && category.isNotEmpty) 'category': category,
      if (description != null && description.isNotEmpty)
        'description': description,
    }) as Map<String, dynamic>;
    return res['id'] as String;
  }

  Future<void> uploadItemPhoto(String itemId, String filePath) async {
    final form = FormData.fromMap({
      'photo': await MultipartFile.fromFile(filePath),
    });
    await _api.upload('/v1/merchant/menu/$itemId/photo', form);
  }

  Future<void> uploadMerchantPhoto(String merchantId, String filePath) async {
    final form = FormData.fromMap({
      'photo': await MultipartFile.fromFile(filePath),
    });
    await _api.upload('/v1/merchant/merchants/$merchantId/photo', form);
  }

  Future<void> setItemAvailable(String itemId, bool available) async {
    await _api.post(
      '/v1/merchant/menu/$itemId/availability',
      body: {'is_available': available},
    );
  }

  Future<bool> setOpen(String merchantId, bool isOpen) async {
    final res = await _api.post(
      '/v1/merchant/open',
      body: {'merchant_id': merchantId, 'is_open': isOpen},
    ) as Map<String, dynamic>;
    return (res['is_open'] as bool?) ?? isOpen;
  }

  Future<List<CustomerOrder>> orders({String? status}) async {
    final res = await _api.get(
      '/v1/merchant/orders',
      query: {if (status != null) 'status': status},
    ) as List;
    return res
        .cast<Map<String, dynamic>>()
        .map((j) => CustomerOrder.fromJson(j))
        .toList();
  }

  Future<CustomerOrder> orderDetail(String id) async {
    final res = await _api.get('/v1/orders/$id') as Map<String, dynamic>;
    final order = res['order'] as Map<String, dynamic>;
    final items = (res['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(OrderItem.fromJson)
        .toList();
    return CustomerOrder.fromJson(order, items: items);
  }

  Future<void> advance(String orderId, String status) async {
    await _api.post('/v1/orders/$orderId/status', body: {'status': status});
  }
}

final merchantRepositoryProvider = Provider<MerchantRepository>((ref) {
  return MerchantRepository(ref.watch(apiClientProvider));
});

final myMerchantsProvider =
    FutureProvider.autoDispose<List<Merchant>>((ref) async {
  return ref.watch(merchantRepositoryProvider).myMerchants();
});

final merchantMenuProvider = FutureProvider.autoDispose
    .family<List<MenuItem>, String>((ref, merchantId) async {
  return ref.watch(merchantRepositoryProvider).menu(merchantId);
});

/// Live order queue for a merchant, polled every 6s. `arg` is the merchant id.
final merchantOrdersProvider = StreamProvider.autoDispose
    .family<List<CustomerOrder>, String>((ref, merchantId) async* {
  final repo = ref.watch(merchantRepositoryProvider);
  while (true) {
    final all = await repo.orders();
    yield all.where((o) => o.merchantId == merchantId).toList();
    await Future<void>.delayed(const Duration(seconds: 6));
  }
});
