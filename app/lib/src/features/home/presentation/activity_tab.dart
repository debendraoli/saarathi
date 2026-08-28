import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../marketplace/data/marketplace_repository.dart';
import '../../marketplace/domain/models.dart';
import '../../ride/application/ride_controller.dart';
import '../../ride/presentation/trip_history.dart';

/// Activity: food/grocery orders and ride/delivery trips, most-recent first.
/// Both sources page independently (orders and trips are unrelated lists,
/// each with their own "hasMore") — scrolling near the bottom asks each for
/// its next page; one that's already exhausted or mid-fetch just no-ops.
class ActivityTab extends ConsumerStatefulWidget {
  const ActivityTab({super.key});

  @override
  ConsumerState<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends ConsumerState<ActivityTab> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) {
      ref.read(myOrdersPagedProvider.notifier).loadMore();
      ref.read(myTripsPagedProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final ordersState = ref.watch(myOrdersPagedProvider);
    final tripsState = ref.watch(myTripsPagedProvider);

    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([
          ref.read(myOrdersPagedProvider.notifier).refresh(),
          ref.read(myTripsPagedProvider.notifier).refresh(),
        ]);
      },
      child: tripsState.when(
        loading: () =>
            const SkeletonList(padding: EdgeInsets.symmetric(vertical: 8)),
        error: (_, __) => ListView(
          children: [
            const SizedBox(height: 120),
            ErrorRetry(
              message: l.errorNetwork,
              onRetry: () => ref.invalidate(myTripsPagedProvider),
            ),
          ],
        ),
        data: (tripsPage) {
          final orders = ordersState.value?.items ?? const [];
          final trips = tripsPage.items;
          if (orders.isEmpty && trips.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: 140),
                Center(child: Text(l.activityEmpty)),
              ],
            );
          }
          final loadingMore = tripsPage.loading ||
              (ordersState.value?.loading ?? false);
          return ListView(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (orders.isNotEmpty) ...[
                _SectionHeader(l.merchantOrders),
                for (final o in orders) _OrderTile(order: o),
              ],
              if (trips.isNotEmpty) ...[
                _SectionHeader(l.tabActivity),
                for (final t in trips) TripTile(trip: t),
              ],
              if (loadingMore)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                ),
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
