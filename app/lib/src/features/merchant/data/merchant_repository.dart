import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';
import '../../../shared/provider_retry.dart';
import '../../../shared/request_ring.dart';
import '../../../shared/resilient_poll.dart';
import '../../marketplace/domain/models.dart';
import '../domain/models.dart';

/// Merchant-owner surface: the store(s) a user owns, their menu, and the live
/// order queue. Backed by the /v1/merchant/* endpoints (owner- or staff-scoped).
class MerchantRepository {
  MerchantRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;

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

  Future<List<Merchant>> myMerchants() => cacheThroughList(
        prefs: _prefs,
        key: 'cache.merchant.myMerchants',
        fetch: () => _api.get('/v1/merchant/merchants'),
        parse: Merchant.fromJson,
      );

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

  /// [limit]/[offset] are left unset by the ring/notification poll loop
  /// below (`_merchantOrdersPollProvider`), which needs the *whole* active
  /// set every tick to detect a genuinely new order id — only the order
  /// queue screen's own infinite-scroll list passes them.
  Future<List<CustomerOrder>> orders(
      {String? status, int? limit, int? offset}) async {
    final res = await _api.get(
      '/v1/merchant/orders',
      query: {
        if (status != null) 'status': status,
        if (limit != null) 'limit': limit.toString(),
        if (offset != null) 'offset': offset.toString(),
      },
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

  /// Returns true when marking an order 'ready' found no couriers nearby at
  /// that moment (the backend still attempts dispatch regardless — its own
  /// progressive-widening search may still find one — this is a heads-up
  /// for the merchant, not a block).
  Future<bool> advance(String orderId, String status) async {
    final res = await _api.post(
      '/v1/orders/$orderId/status',
      body: {'status': status},
    ) as Map<String, dynamic>;
    return res['no_couriers_nearby'] == true;
  }

  Future<MerchantAnalytics> analytics(String merchantId) async {
    final res = await _api.get('/v1/merchant/merchants/$merchantId/analytics')
        as Map<String, dynamic>;
    return MerchantAnalytics.fromJson(res);
  }

  Future<List<MerchantOffer>> offers(String merchantId) => cacheThroughList(
        prefs: _prefs,
        key: 'cache.merchant.offers.$merchantId',
        fetch: () => _api.get('/v1/merchant/merchants/$merchantId/offers'),
        parse: MerchantOffer.fromJson,
      );

  Future<void> createOffer({
    required String merchantId,
    required String kind,
    double? value,
    double? maxDiscount,
    double minOrderAmount = 0,
    DateTime? startsAt,
    DateTime? endsAt,
    int? dailyStartMinute,
    int? dailyEndMinute,
  }) async {
    await _api.post('/v1/merchant/merchants/$merchantId/offers', body: {
      'kind': kind,
      if (value != null) 'value': value,
      if (maxDiscount != null) 'max_discount': maxDiscount,
      'min_order_amount': minOrderAmount,
      if (startsAt != null) 'starts_at': startsAt.toUtc().toIso8601String(),
      if (endsAt != null) 'ends_at': endsAt.toUtc().toIso8601String(),
      if (dailyStartMinute != null) 'daily_start_minute': dailyStartMinute,
      if (dailyEndMinute != null) 'daily_end_minute': dailyEndMinute,
    });
  }

  Future<void> deactivateOffer(String merchantId, String offerId) async {
    await _api
        .post('/v1/merchant/merchants/$merchantId/offers/$offerId/deactivate');
  }
}

final merchantRepositoryProvider = Provider<MerchantRepository>((ref) {
  return MerchantRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

final myMerchantsProvider =
    FutureProvider.autoDispose<List<Merchant>>((ref) async {
  return ref.watch(merchantRepositoryProvider).myMerchants();
}, retry: shortNetworkRetry);

final merchantMenuProvider = FutureProvider.autoDispose
    .family<List<MenuItem>, String>((ref, merchantId) async {
  return ref.watch(merchantRepositoryProvider).menu(merchantId);
}, retry: shortNetworkRetry);

final merchantAnalyticsProvider = FutureProvider.autoDispose
    .family<MerchantAnalytics, String>((ref, merchantId) async {
  return ref.watch(merchantRepositoryProvider).analytics(merchantId);
}, retry: shortNetworkRetry);

/// All offers (active + inactive) for the owner's management screen.
final merchantOffersProvider = FutureProvider.autoDispose
    .family<List<MerchantOffer>, String>((ref, merchantId) async {
  return ref.watch(merchantRepositoryProvider).offers(merchantId);
}, retry: shortNetworkRetry);

/// Single underlying poll loop for a merchant's order queue, polled every
/// 6s. Rings once per genuinely new order id (not every poll tick), same
/// pattern as [driverOffersProvider] — the "is this new" comparison lives
/// here with the polling loop, not duplicated in whatever screen is
/// watching. [merchantOrdersProvider] and [merchantOrdersStaleProvider]
/// both derive from this one fetch cycle.
final _merchantOrdersPollProvider = StreamProvider.autoDispose
    .family<Poll<List<CustomerOrder>>, String>((ref, merchantId) {
  final repo = ref.watch(merchantRepositoryProvider);
  // Stay alive with zero widget watchers — otherwise navigating away from
  // the order queue (e.g. into an order's detail screen) disposes this
  // (autoDispose's default) and silently stops the ring while new orders
  // keep arriving. Same fix as `driverOffersProvider`.
  ref.keepAlive();
  // Null (not empty) until the first fetch lands — an empty starting set
  // would make every order already open when this screen loads look "new"
  // against it, ringing on open instead of only on a genuine new arrival.
  Set<String>? seen;
  ref.onDispose(RequestRing.stop);
  return resilientPoll(
    fetch: () async {
      final all = await repo.orders();
      final mine = all.where((o) => o.merchantId == merchantId).toList();
      final ids = mine.map((o) => o.id).toSet();
      final lastSeen = seen;
      if (lastSeen != null) {
        final newIds = ids.difference(lastSeen);
        if (newIds.isNotEmpty) {
          RequestRing.play();
          // A real tray notification alongside the ring — same reasoning
          // as `driverOffersProvider`: the ring alone is easy to miss on a
          // busy counter, and is otherwise the only signal that fires while
          // the app is in the foreground.
          unawaited(NotificationService.instance.show(
            newIds.length > 1 ? '${newIds.length} new orders' : 'New order',
            'Tap to view and respond',
          ));
        } else if (ids.isEmpty) {
          RequestRing.stop();
        }
      }
      seen = ids;
      return mine;
    },
    interval: const Duration(seconds: 6),
  );
});

/// The merchant's order queue, self-recovering from transient network
/// failures instead of erroring the whole screen on one flaky poll.
final merchantOrdersProvider = Provider.autoDispose
    .family<AsyncValue<List<CustomerOrder>>, String>((ref, merchantId) {
  return ref
      .watch(_merchantOrdersPollProvider(merchantId))
      .whenData((poll) => poll.value);
});

/// True while showing a stale (last-known) order list because the most
/// recent poll failed.
final merchantOrdersStaleProvider =
    Provider.autoDispose.family<bool, String>((ref, merchantId) {
  return ref.watch(_merchantOrdersPollProvider(merchantId)).value?.stale ??
      false;
});

/// Forces an immediate re-fetch of the order queue — after an order action
/// (accept/reject/advance) or a pull-to-refresh, or to restart the poll
/// loop after it's given up entirely. Invalidating [merchantOrdersProvider]
/// alone wouldn't do either, since it's a thin derived view over this
/// provider, not the poll loop itself.
void refreshMerchantOrders(WidgetRef ref, String merchantId) =>
    ref.invalidate(_merchantOrdersPollProvider(merchantId));
