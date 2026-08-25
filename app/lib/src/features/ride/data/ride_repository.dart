import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/offline/json_cache.dart';
import '../../../core/prefs.dart';
import '../domain/models.dart';

class RideRepository {
  RideRepository(this._api, this._prefs);

  final ApiClient _api;
  final SharedPreferences _prefs;

  Future<FareEstimate> estimate(RideDraft draft,
      {CancelToken? cancelToken}) async {
    final res = await _api.post(
      '/v1/rides/estimate',
      body: {
        'origin': draft.pickup.toJson(),
        'dest': draft.destination.toJson(),
        'stops': [for (final s in draft.stops) s.toJson()],
        'vehicle_class': draft.vehicleClass.wire,
      },
      cancelToken: cancelToken,
    );
    return FareEstimate.fromJson(res as Map<String, dynamic>);
  }

  /// [idempotencyKey], when given, should be generated once per booking
  /// attempt (via [newIdempotencyKey]) and reused across retries of that same
  /// tap — a dropped response then replays the original trip instead of
  /// creating a duplicate. Callers that don't pass one get a fresh key per
  /// call, i.e. no retry protection.
  Future<Trip> book(RideDraft draft, {String? idempotencyKey}) async {
    final res = await _api.post(
      '/v1/rides',
      body: {
        'origin': draft.pickup.toJson(),
        'dest': draft.destination.toJson(),
        'stops': [for (final s in draft.stops) s.toJson()],
        'vehicle_class': draft.vehicleClass.wire,
        'payment_method': draft.paymentMethod,
        'pricing_mode': draft.pricingMode,
        if (draft.askFare != null) 'offered_fare': draft.askFare,
        if (draft.radiusKm != null) 'radius_km': draft.radiusKm,
        if (draft.preferredDriverPhone != null &&
            draft.preferredDriverPhone!.trim().isNotEmpty)
          'preferred_driver_phone': draft.preferredDriverPhone,
      },
      headers: {
        'x-idempotency-key': idempotencyKey ?? newIdempotencyKey(),
      },
    );
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  /// Rider raises (or lowers) the asking price mid-auction; re-broadcasts to
  /// drivers who were passed over at the old price.
  Future<Trip> changeAsk(String tripId, double amount) async {
    final res = await _api.post('/v1/rides/$tripId/ask', body: {
      'amount': amount,
    });
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  /// Live bids against a bid-mode trip's ask — rider/staff only (blind
  /// bidding: a driver never sees this list).
  Future<List<Bid>> bids(String tripId) async {
    final res = await _api.get('/v1/rides/$tripId/bids') as List;
    return res.cast<Map<String, dynamic>>().map(Bid.fromJson).toList();
  }

  /// Rider accepts a bid — binding, assigns the trip immediately.
  Future<Trip> acceptBid(String tripId, String bidId) async {
    final res = await _api.post('/v1/rides/$tripId/bids/$bidId/accept');
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  /// Driver places or revises a bid against a trip's current ask.
  Future<void> placeBid(String tripId, double amount) =>
      _api.post('/v1/rides/$tripId/bid', body: {'amount': amount});

  Future<Trip> trip(String id) async {
    final res = await _api.get('/v1/rides/$id');
    return Trip.fromJson(res as Map<String, dynamic>);
  }

  /// Counterpart identity for the sticky in-trip card — both sides' name/
  /// phone/rating, plus the driver's vehicle, fleet-partner name and photo.
  Future<TripParticipants> participants(String id) async {
    final res = await _api.get('/v1/rides/$id/participants');
    return TripParticipants.fromJson(res as Map<String, dynamic>);
  }

  /// Road-following route geometry for the map polyline. [points] is the ordered
  /// path (pickup, stops…, destination). Returns a straight line when the routing
  /// engine is unreachable.
  Future<List<LatLng>> routeGeometry(
    List<LatLng> points, {
    String vehicleClass = 'two_wheeler',
  }) async {
    if (points.length < 2) return points;
    final res = await _api.post(
      '/v1/rides/route',
      body: {
        'origin': {'lat': points.first.latitude, 'lng': points.first.longitude},
        'dest': {'lat': points.last.latitude, 'lng': points.last.longitude},
        'stops': [
          for (final p in points.sublist(1, points.length - 1))
            {'lat': p.latitude, 'lng': p.longitude},
        ],
        'vehicle_class': vehicleClass,
      },
    );
    final geom =
        ((res as Map<String, dynamic>)['geometry'] as List?) ?? const [];
    return [
      for (final p in geom)
        LatLng(asDouble((p as Map)['lat']), asDouble(p['lng'])),
    ];
  }

  /// Distance + duration between two points — a thin sibling to
  /// [routeGeometry] hitting the same endpoint, for a live ETA rather than
  /// the map polyline (which discards everything but `geometry`).
  Future<RouteEta> routeEta(
    LatLng from,
    LatLng to, {
    String vehicleClass = 'two_wheeler',
  }) async {
    final res = await _api.post(
      '/v1/rides/route',
      body: {
        'origin': {'lat': from.latitude, 'lng': from.longitude},
        'dest': {'lat': to.latitude, 'lng': to.longitude},
        'stops': [],
        'vehicle_class': vehicleClass,
      },
    ) as Map<String, dynamic>;
    return RouteEta(
      distanceKm: asDouble(res['distance_km']),
      durationSecs: (res['duration_secs'] as num).toInt(),
    );
  }

  Future<RiderStats> myStats() async {
    final res = await _api.get('/v1/rides/mine/stats') as Map<String, dynamic>;
    return RiderStats.fromJson(res);
  }

  Future<DriverGoals> todayGoals() async {
    final res = await _api.get('/v1/rides/driver/today') as Map<String, dynamic>;
    return DriverGoals.fromJson(res);
  }

  Future<DriverEarnings> driverEarnings(String period) async {
    final res = await _api.get(
      '/v1/rides/driver/earnings',
      query: {'period': period},
    ) as Map<String, dynamic>;
    return DriverEarnings.fromJson(res);
  }

  Future<List<Trip>> myTrips() async {
    final trips = await cacheThroughList(
      prefs: _prefs,
      key: 'cache.rides.mytrips',
      fetch: () => _api.get('/v1/rides'),
      parse: Trip.fromJson,
    );
    // No dedicated poll loop for rides (unlike delivery orders) — this is
    // called every time Home/Activity re-fetches, so the schedule call
    // itself has to be the dedup point instead of a status-transition
    // check; the persisted per-trip flag inside it does that.
    for (final t in trips) {
      unawaited(_maybeScheduleReviewReminder(t));
    }
    return trips;
  }

  static int _reviewReminderId(String tripId) => tripId.hashCode & 0x7fffffff;

  /// Schedules the "how was your ride?" nudge ~20 minutes after a trip is
  /// first observed as completed — replaces the old in-app popup (which
  /// interrupted whatever the rider was doing on Home) with a normal
  /// notification they can act on whenever suits them. Deduped per trip via
  /// a persisted flag, same pattern as the merchant order review reminder.
  Future<void> _maybeScheduleReviewReminder(Trip trip) async {
    if (trip.status != TripStatus.completed || trip.rated) return;
    final key = 'reminder.ride.${trip.id}';
    if (_prefs.getBool(key) ?? false) return;
    await _prefs.setBool(key, true);
    final localeCode = _prefs.getString('saarathi.locale');
    final locale = localeCode != null
        ? ui.Locale(localeCode)
        : ui.PlatformDispatcher.instance.locale;
    final l = lookupAppL10n(locale);
    await NotificationService.instance.scheduleDelayed(
      id: _reviewReminderId(trip.id),
      title: l.rideReviewReminderTitle,
      body: l.rideReviewReminderBody,
      delay: const Duration(minutes: 20),
      link: 'saarathi://trip/${trip.id}',
    );
  }

  /// Cancels a pending ride-review reminder — called once the rider rates
  /// the driver before the delay is up, since the nudge is now moot.
  Future<void> cancelReviewReminder(String tripId) =>
      NotificationService.instance.cancel(_reviewReminderId(tripId));

  Future<void> cancel(String id, {String? reason}) => _api.post(
        '/v1/rides/$id/status',
        body: {
          'status': 'cancelled',
          if (reason != null) 'reason': reason,
        },
      );

  /// Driver advances the trip: arriving → in_progress → completed.
  Future<void> updateStatus(String id, String status) =>
      _api.post('/v1/rides/$id/status', body: {'status': status});

  /// Driver publishes live position during an active trip (fanned out over WS).
  Future<void> postLocation(
    String id,
    double lat,
    double lng, {
    double? heading,
    double? speed,
  }) =>
      _api.post('/v1/rides/$id/location', body: {
        'lat': lat,
        'lng': lng,
        if (heading != null) 'heading': heading,
        if (speed != null) 'speed': speed,
      });

  Future<void> rate(String id, int stars, {List<String> tags = const []}) async {
    await _api.post(
      '/v1/rides/$id/rate',
      body: {'stars': stars, 'tags': tags},
    );
    await cancelReviewReminder(id);
  }

  Future<void> sos(String id, {double? lat, double? lng, String? note}) =>
      _api.post(
        '/v1/rides/$id/sos',
        body: {'lat': lat, 'lng': lng, if (note != null) 'note': note},
      );

  /// Approximate (jittered) online-driver positions near [center], purely for
  /// the "searching" map animation — not real dispatch candidates.
  Future<List<LatLng>> nearbyDrivers(LatLng center,
      {double radiusKm = 3}) async {
    final res = await _api.get('/v1/rides/nearby-drivers', query: {
      'lat': center.latitude,
      'lng': center.longitude,
      'radius_km': radiusKm,
    });
    return [
      for (final p in (res as List))
        LatLng(asDouble((p as Map)['lat']), asDouble(p['lng'])),
    ];
  }
}

final rideRepositoryProvider = Provider<RideRepository>((ref) {
  return RideRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});
