import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/geocode_cache.dart';
import '../../../shared/widgets/common.dart';
import '../../places/data/places_repository.dart';
import '../application/ride_controller.dart';
import '../domain/models.dart';
import 'widgets/mini_route_map.dart';

/// A finished trip's static summary — route, fare, driver, cancellation
/// reason. Split out from `TripScreen` (the *live* trip view — swipe
/// controls, live map follow, call/message) because reusing that for a
/// completed/cancelled trip reached from Activities made no sense: none of
/// the live affordances apply, and the live map-follow camera has nothing
/// left to follow.
class TripDetailsScreen extends ConsumerWidget {
  const TripDetailsScreen({super.key, required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(tripDetailsProvider(tripId));
    return Scaffold(
      appBar: AppBar(title: Text(l.tripDetailsTitle)),
      body: async.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(tripDetailsProvider(tripId)),
        ),
        data: (trip) => _Body(trip: trip),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  String? _originLabel;
  String? _destLabel;

  @override
  void initState() {
    super.initState();
    _loadLabels();
  }

  Future<void> _loadLabels() async {
    final repo = ref.read(placesRepositoryProvider);
    final origin = await reverseGeocodeCached(repo, widget.trip.origin);
    final dest = await reverseGeocodeCached(repo, widget.trip.dest);
    if (mounted) {
      setState(() {
        _originLabel = origin;
        _destLabel = dest;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final trip = widget.trip;
    final scheme = Theme.of(context).colorScheme;
    final participants = trip.driverId == null
        ? null
        : ref.watch(tripParticipantsProvider(trip.id)).valueOrNull;
    final driver = participants?.driver;

    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      children: [
        Row(
          children: [
            _StatusChip(status: trip.status),
            const SizedBox(width: 8),
            Text(_fmtDate(trip.createdAt),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 12),
        MiniRouteMap(origin: trip.origin, dest: trip.dest),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.emoji_people_rounded),
                title: Text(l.pickup),
                subtitle: Text(_originLabel ?? '…'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.sports_score_rounded),
                title: Text(l.destination),
                subtitle: Text(_destLabel ?? '…'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.payments_rounded),
                title: Text(l.fare),
                trailing: Text('NPR ${trip.finalFare.toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.straighten_rounded),
                title: Text(l.distanceLabel),
                trailing: Text('${trip.distanceKm.toStringAsFixed(1)} km'),
              ),
              if (trip.vehicleClass != null) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.directions_car_rounded),
                  title: Text(l.vehicleLabel),
                  trailing: Text(trip.vehicleClass!),
                ),
              ],
            ],
          ),
        ),
        if (trip.status == TripStatus.cancelled &&
            trip.cancelReason != null) ...[
          const SizedBox(height: 16),
          Card(
            color: scheme.errorContainer,
            child: ListTile(
              leading: Icon(Icons.info_outline_rounded, color: scheme.onErrorContainer),
              title: Text(l.cancelReasonLabel,
                  style: TextStyle(color: scheme.onErrorContainer)),
              subtitle: Text(trip.cancelReason!,
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          ),
        ],
        if (driver != null) ...[
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.surfaceContainerHighest,
                backgroundImage: driver.photoUrl != null
                    ? NetworkImage(driver.photoUrl!)
                    : null,
                child: driver.photoUrl == null
                    ? const Icon(Icons.person_rounded)
                    : null,
              ),
              title: Text(driver.name ?? l.driverLabel),
              subtitle: Text([
                if (driver.vehicleLabel.isNotEmpty) driver.vehicleLabel,
                if (driver.plateNumber != null) driver.plateNumber!,
              ].join(' · ')),
              trailing: driver.rating != null
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
                        const SizedBox(width: 2),
                        Text(driver.rating!.toStringAsFixed(1)),
                      ],
                    )
                  : null,
            ),
          ),
        ],
      ],
    );
  }

  static String _fmtDate(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final TripStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      TripStatus.completed => ('completed', scheme.primary),
      TripStatus.cancelled => ('cancelled', scheme.error),
      TripStatus.noDriver => ('no driver', scheme.error),
      _ => ('active', scheme.tertiary),
    };
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label, style: TextStyle(color: color, fontSize: 11)),
      side: BorderSide(color: color.withValues(alpha: 0.4)),
      backgroundColor: color.withValues(alpha: 0.08),
    );
  }
}
