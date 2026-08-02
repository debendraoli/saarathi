import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
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
      loading: () => const LoadingView(),
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
            itemBuilder: (_, i) => _TripTile(trip: list[i]),
          ),
        );
      },
    );
  }
}

class _TripTile extends StatelessWidget {
  const _TripTile({required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDelivery = trip.tripType == 'delivery';
    return Card(
      child: ListTile(
        onTap: trip.isActive
            ? () => context.push('${Routes.trip}/${trip.id}')
            : null,
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
        subtitle: Text(_fmtDate(trip.createdAt)),
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
