import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../application/ride_controller.dart';
import '../application/trip_ws.dart';
import '../data/ride_repository.dart';
import '../domain/models.dart';
import 'widgets/map_view.dart';

/// One screen for the whole live ride: searching → driver on the way → on trip →
/// completed. Status comes from polling; the driver pin from the trip WS.
class TripScreen extends ConsumerWidget {
  const TripScreen({super.key, required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final tripAsync = ref.watch(tripStreamProvider(tripId));
    final driverLoc = ref.watch(tripLocationProvider(tripId)).valueOrNull;

    return Scaffold(
      body: tripAsync.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(tripStreamProvider(tripId)),
        ),
        data: (trip) {
          return Stack(
            children: [
              MapView(
                center: driverLoc ?? trip.origin,
                route: [trip.origin, trip.dest],
                pins: [
                  MapPin(trip.origin, Icons.trip_origin,
                      Theme.of(context).colorScheme.primary),
                  MapPin(trip.dest, Icons.location_on_rounded,
                      Theme.of(context).colorScheme.secondary),
                  if (driverLoc != null)
                    MapPin(driverLoc, Icons.navigation_rounded,
                        Theme.of(context).colorScheme.tertiary),
                ],
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _SosButton(tripId: tripId),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: _StatusSheet(trip: trip),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusSheet extends ConsumerWidget {
  const _StatusSheet({required this.trip});
  final Trip trip;

  (IconData, String, String) _display(AppL10n l) {
    switch (trip.status) {
      case TripStatus.searching:
      case TripStatus.requested:
        return (Icons.search_rounded, l.findingDriver, l.findingDriverBody);
      case TripStatus.accepted:
      case TripStatus.arriving:
        return (Icons.directions_car_rounded, l.driverAssigned, l.statusArriving);
      case TripStatus.inProgress:
        return (Icons.navigation_rounded, l.statusOnTrip, '');
      case TripStatus.completed:
        return (Icons.check_circle_rounded, l.statusCompleted, '');
      case TripStatus.noDriver:
        return (Icons.search_off_rounded, l.noDriverFound, l.noDriverFoundBody);
      default:
        return (Icons.info_outline_rounded, l.statusArriving, '');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final (icon, title, body) = _display(l);
    final searching = trip.status == TripStatus.searching ||
        trip.status == TripStatus.requested;
    final done = trip.status == TripStatus.completed ||
        trip.status == TripStatus.cancelled ||
        trip.status == TripStatus.noDriver;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(icon,
                      color: Theme.of(context).colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (body.isNotEmpty)
                        Text(body,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.onSurfaceVariant,
                                )),
                    ],
                  ),
                ),
                if (searching)
                  const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
              ],
            ),
            if (!done && !searching) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.call_rounded),
                      label: Text(l.callDriver),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {},
                      icon: const Icon(Icons.ios_share_rounded),
                      label: Text(l.shareTrip),
                    ),
                  ),
                ],
              ),
            ],
            if (searching) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  await ref.read(rideRepositoryProvider).cancel(trip.id);
                  if (context.mounted) context.go(Routes.home);
                },
                child: Text(l.cancelRide),
              ),
            ],
            if (done) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => context.go(Routes.home),
                child: Text(l.actionDone),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SosButton extends ConsumerWidget {
  const _SosButton({required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return FloatingActionButton.extended(
      heroTag: 'sos',
      backgroundColor: Theme.of(context).colorScheme.error,
      foregroundColor: Theme.of(context).colorScheme.onError,
      icon: const Icon(Icons.emergency_share_rounded),
      label: Text(l.sos),
      onPressed: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(l.sos),
            content: Text(l.sosConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l.sos),
              ),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.sos)),
          );
        }
      },
    );
  }
}
