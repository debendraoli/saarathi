import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../application/ride_controller.dart';
import '../../../domain/models.dart';

/// Distance, live ETA (recomputed from the driver's current position as it
/// updates), and fare, in one compact row — visible across every active
/// status, not just once the trip is done. Distance/duration come straight
/// off the trip (computed once at booking, from the route), so they're
/// available even before a driver's been found.
class EtaFareRow extends ConsumerWidget {
  const EtaFareRow({
    super.key,
    required this.trip,
    required this.driverLoc,
    this.showFare = true,
  });
  final Trip trip;
  final LatLng? driverLoc;

  /// Bid-mode trips already show the rider's live ask in [FareStepper] right
  /// below this row — repeating the algorithmic estimate here too would put
  /// two unlabeled fare numbers on screen at once, so callers that already
  /// show their own fare can turn this one off.
  final bool showFare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final routingToPickup = trip.status == TripStatus.accepted ||
        trip.status == TripStatus.arriving;
    final routingToDest = trip.status == TripStatus.inProgress;

    String? etaText;
    if ((routingToPickup || routingToDest) && driverLoc != null) {
      final target = routingToPickup ? trip.origin : trip.dest;
      final eta =
          ref.watch(tripEtaProvider(EtaQuery(driverLoc!, target))).value;
      if (eta != null) {
        etaText = routingToPickup
            ? l.etaArriving(eta.durationMins)
            : l.etaToDestination(eta.durationMins);
      }
    } else if (trip.durationSecs != null &&
        (trip.status == TripStatus.searching ||
            trip.status == TripStatus.requested)) {
      etaText = l.etaToDestination((trip.durationSecs! / 60).ceil());
    }

    return Row(
      children: [
        if (trip.distanceKm > 0) ...[
          Icon(Icons.route_rounded,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('${trip.distanceKm.toStringAsFixed(1)} km',
              style: theme.textTheme.bodyMedium),
          const SizedBox(width: 14),
        ],
        if (etaText != null) ...[
          Icon(Icons.schedule_rounded,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(etaText, style: theme.textTheme.bodyMedium),
        ],
        const Spacer(),
        if (showFare)
          Text(
            'NPR ${trip.finalFare.toStringAsFixed(2)}',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
      ],
    );
  }
}
