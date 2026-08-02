import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ride_repository.dart';
import '../domain/models.dart';

/// One-shot fare estimate for a drafted ride (auto-disposed when unused).
final fareEstimateProvider =
    FutureProvider.autoDispose.family<FareEstimate, RideDraft>((ref, draft) {
  return ref.watch(rideRepositoryProvider).estimate(draft);
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
