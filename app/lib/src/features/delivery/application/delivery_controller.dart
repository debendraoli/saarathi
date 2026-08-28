import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/provider_retry.dart';
import '../data/delivery_repository.dart';
import '../domain/models.dart';

/// Pricing-relevant inputs for a parcel estimate — deliberately narrower than
/// [ParcelDraft] (no recipient/COD/note) so typing into those fields doesn't
/// invalidate the cached estimate. Value equality is load-bearing here: a
/// `.family` provider keyed by a type without it refetches on every rebuild
/// instead of reusing the cached call (bit the ride booking flow once
/// already — see `RideDraft`'s own equality for the full story).
class DeliveryEstimateQuery {
  const DeliveryEstimateQuery({
    required this.origin,
    required this.dest,
    required this.size,
    required this.fragile,
  });

  final LatLng origin;
  final LatLng dest;
  final ParcelSize size;
  final bool fragile;

  @override
  bool operator ==(Object other) =>
      other is DeliveryEstimateQuery &&
      other.origin == origin &&
      other.dest == dest &&
      other.size == size &&
      other.fragile == fragile;

  @override
  int get hashCode => Object.hash(origin, dest, size, fragile);
}

final deliveryEstimateProvider = FutureProvider.autoDispose
    .family<DeliveryEstimate, DeliveryEstimateQuery>((ref, q) {
  return ref.watch(deliveryRepositoryProvider).estimate(
        origin: q.origin,
        dest: q.dest,
        size: q.size,
        fragile: q.fragile,
      );
}, retry: shortNetworkRetry);
