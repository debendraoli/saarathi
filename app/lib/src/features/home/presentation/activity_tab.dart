import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../../marketplace/data/marketplace_repository.dart';
import '../../marketplace/domain/models.dart';
import '../../ride/application/ride_controller.dart';
import '../../ride/presentation/trip_history.dart';

/// Activity: food/grocery orders and ride/delivery trips, most-recent first.
class ActivityTab extends ConsumerWidget {
  const ActivityTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final orders = ref.watch(myOrdersProvider).valueOrNull ?? const [];
    final trips = ref.watch(myTripsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(myOrdersProvider);
        ref.invalidate(myTripsProvider);
      },
      child: trips.when(
        loading: () => const LoadingView(),
        error: (_, __) => ListView(
          children: [
            const SizedBox(height: 120),
            ErrorRetry(
              message: l.errorNetwork,
              onRetry: () => ref.invalidate(myTripsProvider),
            ),
          ],
        ),
        data: (tripList) {
          if (orders.isEmpty && tripList.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: 140),
                Center(child: Text(l.activityEmpty)),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (orders.isNotEmpty) ...[
                _SectionHeader(l.merchantOrders),
                for (final o in orders)
                  _OrderTile(order: o),
              ],
              if (tripList.isNotEmpty) ...[
                _SectionHeader(l.tabActivity),
                for (final t in tripList) TripTile(trip: t),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});
  final CustomerOrder order;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: () => context.push('${Routes.order}/${order.id}'),
        leading: CircleAvatar(
          backgroundColor: scheme.surfaceContainerHighest,
          child: Icon(Icons.shopping_bag_rounded, color: scheme.primary),
        ),
        title: Text(
          order.merchantName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text('NPR ${order.total.toStringAsFixed(0)}'),
        trailing: Text(
          order.status,
          style: TextStyle(
            color: order.isActive ? scheme.primary : scheme.outline,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
