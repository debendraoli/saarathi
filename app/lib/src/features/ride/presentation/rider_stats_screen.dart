import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../marketplace/data/marketplace_repository.dart';
import '../../marketplace/domain/models.dart';
import '../application/ride_controller.dart';
import '../domain/models.dart';

/// The rider's own lifetime activity — rides + orders, spend, distance,
/// rating received. Same "stat card" visual language as the wallet and
/// points/badges screens.
class RiderStatsScreen extends ConsumerWidget {
  const RiderStatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final rides = ref.watch(riderStatsProvider);
    final orders = ref.watch(orderStatsProvider);
    final loading = rides.isLoading || orders.isLoading;
    final hasError = rides.hasError || orders.hasError;

    return Scaffold(
      appBar: AppBar(title: Text(l.myStatsAction)),
      body: loading
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 90, height: 13),
                  SizedBox(height: 8),
                  SkeletonStatGrid(),
                  SizedBox(height: 20),
                  SkeletonBox(width: 90, height: 13),
                  SizedBox(height: 8),
                  SkeletonStatGrid(),
                ],
              ),
            )
          : hasError
              ? ErrorRetry(
                  message: l.errorNetwork,
                  onRetry: () {
                    ref.invalidate(riderStatsProvider);
                    ref.invalidate(orderStatsProvider);
                  },
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(riderStatsProvider);
                    ref.invalidate(orderStatsProvider);
                  },
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(16, 16, 16,
                        16 + MediaQuery.of(context).padding.bottom),
                    children: [
                      Text(l.myStatsRidesHeader,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      _RidesSection(stats: rides.value!),
                      const SizedBox(height: 20),
                      Text(l.myStatsOrdersHeader,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      _OrdersSection(stats: orders.value!),
                    ],
                  ),
                ),
    );
  }
}

class _RidesSection extends StatelessWidget {
  const _RidesSection({required this.stats});
  final RiderStats stats;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: l.myStatsTotalRides,
                value: '${stats.totalRides}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: l.myStatsTotalSpend,
                value: 'NPR ${stats.totalSpend.toStringAsFixed(0)}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: l.myStatsDistanceTraveled,
                value: '${stats.totalDistanceKm.toStringAsFixed(1)} km',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: l.myStatsRatingReceived,
                value: stats.avgRating == null
                    ? '—'
                    : stats.avgRating!.toStringAsFixed(1),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OrdersSection extends StatelessWidget {
  const _OrdersSection({required this.stats});
  final OrderStats stats;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: l.myStatsTotalOrders,
            value: '${stats.totalOrders}',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: l.myStatsTotalSpend,
            value: 'NPR ${stats.totalSpent.toStringAsFixed(0)}',
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}
