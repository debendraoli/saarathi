import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../marketplace/domain/models.dart';
import '../data/merchant_repository.dart';
import '../domain/models.dart';

/// Store sales/order analytics for the owning merchant — total & today
/// order counts, revenue, top-selling items, and rating breakdown. Same
/// "big number card" visual language as `wallet_screen.dart`.
class MerchantAnalyticsScreen extends ConsumerWidget {
  const MerchantAnalyticsScreen({super.key, required this.merchant});
  final Merchant merchant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(merchantAnalyticsProvider(merchant.id));

    return Scaffold(
      appBar: AppBar(title: Text(l.storeAnalyticsTitle)),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(merchantAnalyticsProvider(merchant.id)),
        ),
        data: (a) => RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(merchantAnalyticsProvider(merchant.id)),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            children: [
              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      label: l.storeTotalRevenue,
                      value: 'NPR ${a.overview.totalRevenue.toStringAsFixed(0)}',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      label: l.storeTotalOrders,
                      value: '${a.overview.totalOrders}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      label: l.storeAvgOrderValue,
                      value: 'NPR ${a.overview.avgOrderValue.toStringAsFixed(0)}',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      label: l.storeCancelledOrders,
                      value: '${a.overview.cancelledOrders}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(l.storeTodayHeader,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _TodayStat(
                          label: l.merchantOrdersToday,
                          value: '${a.today.totalOrders}',
                        ),
                      ),
                      Expanded(
                        child: _TodayStat(
                          label: l.merchantRevenueToday,
                          value: 'NPR ${a.today.totalRevenue.toStringAsFixed(0)}',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (a.topItems.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(l.storeTopItemsHeader,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final item in a.topItems) _TopItemTile(item: item),
                    ],
                  ),
                ),
              ],
              if (a.ratingBreakdown.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(l.storeRatingBreakdownHeader,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Column(
                      children: [
                        for (final b in a.ratingBreakdown)
                          _RatingBar(
                            bucket: b,
                            maxCount: a.ratingBreakdown
                                .map((r) => r.count)
                                .reduce((v, e) => v > e ? v : e),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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

class _TodayStat extends StatelessWidget {
  const _TodayStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style:
                theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _TopItemTile extends StatelessWidget {
  const _TopItemTile({required this.item});
  final TopMenuItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.local_fire_department_rounded, color: scheme.primary),
      title: Text(item.name),
      subtitle: Text('${item.units} sold'),
      trailing: Text(
        'NPR ${item.revenue.toStringAsFixed(0)}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _RatingBar extends StatelessWidget {
  const _RatingBar({required this.bucket, required this.maxCount});
  final RatingBucket bucket;
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = maxCount == 0 ? 0.0 : bucket.count / maxCount;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Row(
              children: [
                Text('${bucket.stars}'),
                const SizedBox(width: 2),
                const Icon(Icons.star_rounded, size: 14, color: Colors.amber),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 28,
            child: Text('${bucket.count}', textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
