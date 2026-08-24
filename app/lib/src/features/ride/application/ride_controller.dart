import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/geocode_cache.dart';
import '../../../shared/resilient_poll.dart';
import '../../places/data/places_repository.dart';
import '../data/ride_repository.dart';
import '../domain/models.dart';

/// One-shot fare estimate for a drafted ride (auto-disposed when unused).
final fareEstimateProvider =
    FutureProvider.autoDispose.family<FareEstimate, RideDraft>((ref, draft) {
  return ref.watch(rideRepositoryProvider).estimate(draft);
});

/// An ordered path (pickup → stops → destination) + profile for a route lookup.
/// Value equality over the point list so identical paths share one request and
/// don't refetch on every rebuild.
class RouteQuery {
  const RouteQuery(this.points, this.vehicleClass);
  final List<LatLng> points;
  final String vehicleClass;

  @override
  bool operator ==(Object other) =>
      other is RouteQuery &&
      other.vehicleClass == vehicleClass &&
      _samePoints(other.points, points);

  @override
  int get hashCode => Object.hash(vehicleClass, Object.hashAll(points));

  static bool _samePoints(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Road-following polyline for a pickup → stops → destination path.
final routeGeometryProvider =
    FutureProvider.autoDispose.family<List<LatLng>, RouteQuery>((ref, q) {
  return ref
      .watch(rideRepositoryProvider)
      .routeGeometry(q.points, vehicleClass: q.vehicleClass);
});

/// Two points to route between for a live ETA. Value equality (same shape as
/// [RouteQuery]) means an unchanged driver position reuses the cached
/// result instead of re-fetching — no manual throttling needed, the ETA
/// simply re-requests exactly when the driver's live location actually
/// moves.
class EtaQuery {
  const EtaQuery(this.from, this.to);
  final LatLng from;
  final LatLng to;

  @override
  bool operator ==(Object other) =>
      other is EtaQuery && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Live distance/duration between two points — see [EtaQuery].
final tripEtaProvider =
    FutureProvider.autoDispose.family<RouteEta, EtaQuery>((ref, q) {
  return ref.watch(rideRepositoryProvider).routeEta(q.from, q.to);
});

/// Single underlying poll loop for a trip — [tripStreamProvider] and
/// [tripStaleProvider] both derive from this one fetch cycle rather than
/// each polling independently.
final _tripPollProvider =
    StreamProvider.autoDispose.family<Poll<Trip>, String>((ref, id) {
  final repo = ref.watch(rideRepositoryProvider);
  return resilientPoll(
    fetch: () => repo.trip(id),
    interval: const Duration(seconds: 3),
    stopWhen: (trip) => !trip.isActive,
  );
});

/// The live trip, self-recovering from transient network failures — a flaky
/// tick keeps showing the last-known trip instead of erroring the whole
/// screen. See [tripStaleProvider] to show a small "reconnecting" indicator
/// during that window instead of just going silent.
final tripStreamProvider =
    Provider.autoDispose.family<AsyncValue<Trip>, String>((ref, id) {
  return ref.watch(_tripPollProvider(id)).whenData((poll) => poll.value);
});

/// True while the trip screen is showing a stale (last-known) value because
/// the most recent poll failed.
final tripStaleProvider = Provider.autoDispose.family<bool, String>((ref, id) {
  return ref.watch(_tripPollProvider(id)).valueOrNull?.stale ?? false;
});

/// Restarts the actual poll loop after it's given up (past
/// `maxInitialFailures` with no value ever fetched) — invalidating
/// [tripStreamProvider] alone wouldn't do this, since it's a thin derived
/// view over this provider, not the poll loop itself.
void retryTripPoll(WidgetRef ref, String id) =>
    ref.invalidate(_tripPollProvider(id));

/// Counterpart identity for the sticky in-trip card. Re-fetches only when the
/// trip's status actually changes (e.g. phone visibility flips once a trip
/// ends) rather than on every 3s poll tick.
final tripParticipantsProvider =
    FutureProvider.autoDispose.family<TripParticipants, String>((ref, id) {
  ref.watch(tripStreamProvider(id).select((v) => v.valueOrNull?.status));
  return ref.read(rideRepositoryProvider).participants(id);
});

/// Human label for a trip's destination, for the in-trip status body
/// ("arriving at …" / "on the way to …"). The dest point never changes
/// mid-trip, so this only ever fetches once per trip (cached process-wide
/// besides — see `reverseGeocodeCached`).
final tripDestLabelProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, tripId) {
  final dest =
      ref.watch(tripStreamProvider(tripId).select((v) => v.valueOrNull?.dest));
  if (dest == null) return Future.value(null);
  return reverseGeocodeCached(ref.watch(placesRepositoryProvider), dest);
});

/// Same as [tripDestLabelProvider] but for the pickup point — used on the
/// post-trip rating sheet, which wants both ends of the trip, not just
/// "where it's headed" the way the in-progress status body does.
final tripOriginLabelProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, tripId) {
  final origin = ref
      .watch(tripStreamProvider(tripId).select((v) => v.valueOrNull?.origin));
  if (origin == null) return Future.value(null);
  return reverseGeocodeCached(ref.watch(placesRepositoryProvider), origin);
});

/// The signed-in user's own trips, newest first (Activity tab).
final myTripsProvider = FutureProvider.autoDispose<List<Trip>>((ref) {
  return ref.watch(rideRepositoryProvider).myTrips();
});

/// The signed-in rider's lifetime ride stats (My Stats screen).
final riderStatsProvider = FutureProvider.autoDispose<RiderStats>((ref) {
  return ref.watch(rideRepositoryProvider).myStats();
});

/// The signed-in driver's progress toward any live daily ride goal.
final driverTodayGoalsProvider = FutureProvider.autoDispose<DriverGoals>((ref) {
  return ref.watch(rideRepositoryProvider).todayGoals();
});

/// Polls live bids for a bid-mode trip. Stops on its own once the trip
/// leaves 'requested' (accepted/cancelled) — no point polling a resolved
/// auction — mirroring `tripStreamProvider`'s own stop condition.
final tripBidsProvider =
    StreamProvider.autoDispose.family<List<Bid>, String>((ref, tripId) async* {
  final repo = ref.watch(rideRepositoryProvider);
  while (true) {
    final trip = ref.read(tripStreamProvider(tripId)).valueOrNull;
    if (trip != null && trip.status != TripStatus.requested) {
      yield const [];
      return;
    }
    try {
      yield await repo.bids(tripId);
    } catch (_) {
      yield const [];
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});
