import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

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

/// Polls a trip's status until it leaves an active state. Cheap + connectivity
/// tolerant (a dropped poll just retries next tick); the trip WS layers live
/// driver location on top in the tracking screen.
final tripStreamProvider =
    StreamProvider.autoDispose.family<Trip, String>((ref, id) async* {
  final repo = ref.watch(rideRepositoryProvider);
  while (true) {
    final trip = await repo.trip(id);
    yield trip;
    if (!trip.isActive) break;
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});

/// The signed-in user's own trips, newest first (Activity tab).
final myTripsProvider = FutureProvider.autoDispose<List<Trip>>((ref) {
  return ref.watch(rideRepositoryProvider).myTrips();
});
