import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/geocode_cache.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../places/data/places_repository.dart';
import '../application/ride_controller.dart';
import '../domain/models.dart';

/// The user's trip & delivery history (Activity tab). Pull to refresh.
class TripHistoryList extends ConsumerWidget {
  const TripHistoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final trips = ref.watch(myTripsProvider);

    return trips.when(
      loading: () => const SkeletonList(padding: EdgeInsets.all(12)),
      error: (_, __) => ErrorRetry(
        message: l.errorNetwork,
        onRetry: () => ref.invalidate(myTripsProvider),
      ),
      data: (list) {
        if (list.isEmpty) {
          return _Empty(label: l.activityEmpty);
        }
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(myTripsProvider),
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => TripTile(trip: list[i]),
          ),
        );
      },
    );
  }
}

class TripTile extends ConsumerStatefulWidget {
  const TripTile({super.key, required this.trip});
  final Trip trip;

  @override
  ConsumerState<TripTile> createState() => _TripTileState();
}

class _TripTileState extends ConsumerState<TripTile> {
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
    final trip = widget.trip;
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final isDelivery = trip.tripType == 'delivery';
    return Card(
      child: ListTile(
        onTap: () => context.push('${Routes.trip}/${trip.id}'),
        leading: CircleAvatar(
          backgroundColor: scheme.surfaceContainerHighest,
          child: Icon(
            isDelivery
                ? Icons.inventory_2_rounded
                : (trip.vehicleClass == 'four_wheeler'
                    ? Icons.directions_car_rounded
                    : Icons.two_wheeler_rounded),
            color: scheme.primary,
          ),
        ),
        title: Text(
          '${trip.distanceKm.toStringAsFixed(1)} km · NPR ${trip.finalFare.toStringAsFixed(0)}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 2),
            _RoutePreview(
              origin: _originLabel,
              dest: _destLabel,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            Text(_fmtDate(trip.createdAt), style: theme.textTheme.bodySmall),
          ],
        ),
        isThreeLine: true,
        trailing: _StatusChip(status: trip.status),
      ),
    );
  }

  static String _fmtDate(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

/// "Origin → Destination", one line, truncated — shown while a label is
/// still resolving (or unavailable) as "…" rather than a jarring layout
/// jump once it loads.
class _RoutePreview extends StatelessWidget {
  const _RoutePreview({required this.origin, required this.dest, this.style});
  final String? origin;
  final String? dest;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${origin ?? '…'} → ${dest ?? '…'}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
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

class _Empty extends StatelessWidget {
  const _Empty({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.receipt_long_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(label),
        ],
      ),
    );
  }
}
