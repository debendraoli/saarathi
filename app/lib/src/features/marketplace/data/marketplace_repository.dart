import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';
import '../../../shared/paged_notifier.dart';
import '../../../shared/provider_retry.dart';
import '../../../shared/resilient_poll.dart';
import '../../merchant/domain/models.dart' show MerchantOffer;
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

  /// Active, in-window store offers for the customer-facing banner (browse
  /// screen + checkout) — auto-applied at order time, nothing to enter.
  Future<List<MerchantOffer>> activeOffers(String merchantId) async {
    final res =
        await _api.get('/v1/merchants/$merchantId/offers/active') as List;
    return res
        .cast<Map<String, dynamic>>()
        .map(MerchantOffer.fromJson)
        .toList();
  }

  /// Active offers across every nearby open merchant in [vertical] — the
  /// "Offers near you" rail on the browse screen.
  Future<List<NearbyOffer>> nearbyOffers(String vertical, LatLng? at) async {
    final res = await _api.get('/v1/offers/nearby', query: {
      'vertical': vertical,
      if (at != null) 'lat': at.latitude,
      if (at != null) 'lng': at.longitude,
    }) as List;
    return res.cast<Map<String, dynamic>>().map(NearbyOffer.fromJson).toList();
  }

  /// Search items across all open merchants. [sort]: nearest | cheapest | rating.
  Future<List<ItemResult>> searchItems(
    String query, {
    LatLng? at,
    String? vertical,
    String sort = 'nearest',
  }) async {
    if (query.trim().length < 2) return const [];
    final res = await _api.get('/v1/items/search', query: {
      'q': query.trim(),
      'sort': sort,
      if (vertical != null) 'vertical': vertical,
      if (at != null) 'lat': at.latitude,
      if (at != null) 'lng': at.longitude,
    }) as List;
    return res.cast<Map<String, dynamic>>().map(ItemResult.fromJson).toList();
  }

  Future<CustomerOrder> placeOrder({
    required String merchantId,
    required Map<String, int> lines, // menu_item_id -> qty
    required LatLng delivery,
    required String idempotencyKey,
    String? note,
    String paymentMethod = 'cash',
  }) async {
    final res = await _api.post(
      '/v1/orders',
      headers: {'x-idempotency-key': idempotencyKey},
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

  Future<OrderStats> myOrderStats() async {
    final res = await _api.get('/v1/orders/mine/stats') as Map<String, dynamic>;
    return OrderStats.fromJson(res);
  }

  Future<List<CustomerOrder>> myOrders() => cacheThroughList(
        prefs: _prefs,
        key: 'cache.orders',
        fetch: () => _api.get('/v1/orders'),
        parse: (j) => CustomerOrder.fromJson(j),
      );

  /// One page of order history for the Activity tab's infinite scroll — see
  /// `RideRepository.myTripsPage`'s doc comment for why this bypasses
  /// `cacheThroughList` rather than reusing [myOrders].
  Future<List<CustomerOrder>> myOrdersPage(
      {required int limit, required int offset}) async {
    final res = await _api.get('/v1/orders', query: {
      'limit': limit.toString(),
      'offset': offset.toString(),
    });
    return (res as List)
        .map((e) => CustomerOrder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<CustomerOrder> order(String id) async {
    final res = await _api.get('/v1/orders/$id') as Map<String, dynamic>;
    return _parseOrder(res);
  }

  Future<void> rateMerchant(String orderId, int stars,
          {List<String> tags = const []}) =>
      _api.post(
        '/v1/orders/$orderId/rate',
        body: {'stars': stars, 'tags': tags},
      );

  /// The backend only accepts this while the order is still `placed` or
  /// `confirmed` (i.e. before the merchant starts preparing it) — matches
  /// `update_order_status`'s own rule in marketplace.rs, not re-checked
  /// here since the server is the actual authority.
  Future<CustomerOrder> cancelOrder(String orderId) async {
    final res = await _api.post(
      '/v1/orders/$orderId/status',
      body: {'status': 'cancelled'},
    ) as Map<String, dynamic>;
    return _parseOrder(res);
  }

  static int _reminderId(String orderId) => orderId.hashCode & 0x7fffffff;

  /// Schedules the "how was your order?" restaurant-rating nudge ~30 minutes
  /// after an order is first observed as delivered — deliberately delayed so
  /// the customer has actually eaten/opened it before being asked (not fired
  /// immediately, unlike the courier rating). Deduped per order via a
  /// persisted flag so re-polling the same delivered order doesn't
  /// re-schedule it, and so it survives an app restart within the window.
  Future<void> _maybeScheduleReviewReminder(CustomerOrder order) async {
    if (order.status != 'delivered') return;
    final key = 'reminder.merchant.${order.id}';
    if (_prefs.getBool(key) ?? false) return;
    await _prefs.setBool(key, true);
    final localeCode = _prefs.getString('saarathi.locale');
    final locale = localeCode != null
        ? ui.Locale(localeCode)
        : ui.PlatformDispatcher.instance.locale;
    final l = lookupAppL10n(locale);
    await NotificationService.instance.scheduleDelayed(
      id: _reminderId(order.id),
      title: l.reviewReminderTitle,
      body: l.reviewReminderBody(order.merchantName),
      delay: const Duration(minutes: 30),
      link: 'saarathi://order/${order.id}',
    );
  }

  /// Cancels a pending review reminder — called once the customer rates the
  /// merchant before the 30 minutes are up, since the nudge is now moot.
  Future<void> cancelReviewReminder(String orderId) =>
      NotificationService.instance.cancel(_reminderId(orderId));

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

final merchantsProvider = FutureProvider.autoDispose
    .family<List<Merchant>, (String, LatLng?)>((ref, args) {
  return ref.watch(marketplaceRepositoryProvider).merchants(args.$1, args.$2);
}, retry: shortNetworkRetry);

final nearbyOffersProvider = FutureProvider.autoDispose
    .family<List<NearbyOffer>, (String, LatLng?)>((ref, args) {
  return ref
      .watch(marketplaceRepositoryProvider)
      .nearbyOffers(args.$1, args.$2);
}, retry: shortNetworkRetry);

final myOrdersProvider = FutureProvider.autoDispose<List<CustomerOrder>>((ref) {
  return ref.watch(marketplaceRepositoryProvider).myOrders();
}, retry: shortNetworkRetry);

/// Infinite-scroll version of [myOrdersProvider] for the Activity tab's
/// actual list rendering — see `TripsPaged`'s doc comment for the same
/// reasoning (the plain provider above stays for whole-list/small-peek uses
/// elsewhere).
class OrdersPaged extends PagedNotifier<CustomerOrder> {
  @override
  Future<List<CustomerOrder>> fetchPage(int offset, int limit) => ref
      .read(marketplaceRepositoryProvider)
      .myOrdersPage(limit: limit, offset: offset);
}

final myOrdersPagedProvider =
    AsyncNotifierProvider.autoDispose<OrdersPaged, PagedState<CustomerOrder>>(
        OrdersPaged.new);

final orderStatsProvider = FutureProvider.autoDispose<OrderStats>((ref) {
  return ref.watch(marketplaceRepositoryProvider).myOrderStats();
}, retry: shortNetworkRetry);

final merchantDetailProvider = FutureProvider.autoDispose
    .family<(Merchant, List<MenuItem>), String>((ref, id) {
  return ref.watch(marketplaceRepositoryProvider).detail(id);
}, retry: shortNetworkRetry);

/// Active store offers for one merchant — the customer-facing banner on
/// the store's menu screen and at checkout.
final storeOffersProvider = FutureProvider.autoDispose
    .family<List<MerchantOffer>, String>((ref, merchantId) {
  return ref.watch(marketplaceRepositoryProvider).activeOffers(merchantId);
}, retry: shortNetworkRetry);

/// Single underlying poll loop — [orderProvider] and [orderStaleProvider]
/// both derive from this one fetch cycle.
final _orderPollProvider =
    StreamProvider.autoDispose.family<Poll<CustomerOrder>, String>((ref, id) {
  final repo = ref.watch(marketplaceRepositoryProvider);
  String? lastStatus;
  return resilientPoll(
    fetch: () async {
      final order = await repo.order(id);
      if (lastStatus != null &&
          lastStatus != 'delivered' &&
          order.status == 'delivered') {
        repo._maybeScheduleReviewReminder(order);
      }
      lastStatus = order.status;
      return order;
    },
    interval: const Duration(seconds: 4),
    stopWhen: (order) => !order.isActive,
  );
});

/// The live order, self-recovering from transient network failures instead
/// of erroring the whole tracking screen on one flaky poll.
final orderProvider =
    Provider.autoDispose.family<AsyncValue<CustomerOrder>, String>((ref, id) {
  return ref.watch(_orderPollProvider(id)).whenData((poll) => poll.value);
});

/// True while showing a stale (last-known) order because the most recent
/// poll failed — drives a small "reconnecting" banner instead of an error.
final orderStaleProvider = Provider.autoDispose.family<bool, String>((ref, id) {
  return ref.watch(_orderPollProvider(id)).value?.stale ?? false;
});

/// Restarts the poll loop after it's given up entirely (never got a first
/// value) — invalidating [orderProvider] alone wouldn't do this, since it's
/// a thin derived view over this provider, not the poll loop itself.
void retryOrderPoll(WidgetRef ref, String id) =>
    ref.invalidate(_orderPollProvider(id));
