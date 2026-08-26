import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart';
import '../../../core/offline/connectivity.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../marketplace/domain/models.dart';
import '../data/merchant_repository.dart';

/// Every order status that still needs the merchant's attention or is still
/// in flight — broader than the orders screen's "active" filter chip (which
/// only means "just placed, needs accepting"), since a store dashboard
/// should surface an order all the way through preparation and pickup, not
/// just the moment it lands.
const _activeStatuses = {
  'placed',
  'confirmed',
  'preparing',
  'ready',
  'picked_up'
};

/// Standalone route (pushed from the account menu, or a "store approved"
/// deep link) — thin Scaffold wrapper around [MerchantHomeBody].
class MerchantDashboardScreen extends StatelessWidget {
  const MerchantDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppL10n.of(context).merchantStore)),
      body: const MerchantHomeBody(),
    );
  }
}

/// The merchant owner's home content: the one store their registration owns,
/// an open/closed toggle, and entries into the live order queue and menu
/// management. No own Scaffold/AppBar — reused both by
/// [MerchantDashboardScreen] (standalone push) and by `HomeShell` (once the
/// store is approved, this becomes the primary home body, same slot
/// RiderHome/DriverHome fill).
///
/// One registration owns at most one *active* (pending/approved) store
/// (enforced server-side by `merchants_one_active_per_owner_idx`), but
/// `myMerchants()` still returns every historical row for the owner,
/// including past rejections that no longer hold the slot — so the current
/// registration is whichever one isn't rejected, not just the first row.
class MerchantHomeBody extends ConsumerWidget {
  const MerchantHomeBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(myMerchantsProvider);

    return async.when(
      // The real content is one big store card, not a list of rows.
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: _StoreCardSkeleton(),
      ),
      error: (_, __) => ErrorRetry(
        message: l.errorNetwork,
        onRetry: () => ref.invalidate(myMerchantsProvider),
      ),
      data: (merchants) {
        if (merchants.isEmpty) {
          return _EmptyState(message: l.merchantNoStore);
        }
        final current = merchants.firstWhere(
          (m) => !m.isRejected,
          orElse: () => merchants.first,
        );
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(myMerchantsProvider),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            children: [_StoreCard(merchant: current)],
          ),
        );
      },
    );
  }
}

/// Matches [_StoreCard]'s shape — one tall card (icon/name header, then the
/// status/orders content beneath) instead of several list-tile rows.
class _StoreCardSkeleton extends StatelessWidget {
  const _StoreCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                    child: SkeletonBox(width: double.infinity, height: 16)),
              ],
            ),
            const SizedBox(height: 10),
            const SkeletonBox(width: 140, height: 12),
            const SizedBox(height: 20),
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoreCard extends ConsumerStatefulWidget {
  const _StoreCard({required this.merchant});
  final Merchant merchant;

  @override
  ConsumerState<_StoreCard> createState() => _StoreCardState();
}

class _StoreCardState extends ConsumerState<_StoreCard> {
  late bool _open = widget.merchant.isOpen;

  Timer? _retryTimer;
  ProviderSubscription<AsyncValue<bool>>? _connSub;
  int _attempt = 0;
  bool? _pendingOpen;

  @override
  void didUpdateWidget(_StoreCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `_open` was only ever seeded once at first build — a refresh that
    // hands this widget a new `Merchant` (pull-to-refresh, another staff
    // device toggling it, an auto-close-after-hours job) never reached the
    // switch until this whole card was torn down and rebuilt fresh. Skip
    // the resync while our own optimistic toggle is still in flight so it
    // doesn't get clobbered by a response that simply hasn't caught up yet.
    if (_pendingOpen == null &&
        widget.merchant.isOpen != oldWidget.merchant.isOpen) {
      _open = widget.merchant.isOpen;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _connSub?.close();
    super.dispose();
  }

  /// Flips the switch optimistically and retries the real request in the
  /// background — same pattern as trip-status updates elsewhere in the app
  /// (see `TripStatusUpdater`), so toggling while briefly offline doesn't
  /// leave the switch stuck reverted or blocked on a network round-trip.
  /// Unlike the driver's online presence (Redis-backed with a TTL a
  /// connectivity drop can let lapse), `is_open` is a plain persistent DB
  /// column with no expiry — there's nothing to "resume" after a drop, only
  /// this toggle's own request to make resilient.
  void _toggle(bool value) {
    Haptics.tap();
    setState(() => _open = value);
    _pendingOpen = value;
    _connSub ??= ref.listenManual(connectivityProvider, (prev, next) {
      if ((next.valueOrNull ?? false) && _pendingOpen != null) {
        _retryTimer?.cancel();
        _attempt = 0;
        _attemptRun();
      }
    });
    _retryTimer?.cancel();
    _attempt = 0;
    _attemptRun();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final attempt = _attempt++;
    final delaySecs = attempt >= 4 ? 30 : (1 << (attempt + 1)); // 2,4,8,16,30…
    _retryTimer = Timer(Duration(seconds: delaySecs), _attemptRun);
  }

  Future<void> _attemptRun() async {
    final target = _pendingOpen;
    if (target == null) return;
    try {
      final now = await ref
          .read(merchantRepositoryProvider)
          .setOpen(widget.merchant.id, target);
      _pendingOpen = null;
      _retryTimer?.cancel();
      if (mounted) setState(() => _open = now);
    } on ApiException catch (e) {
      if (e.isNetwork) {
        _scheduleRetry();
      } else {
        // A genuine rejection (not connectivity) — revert the optimistic
        // guess and say so, matching the old blocking behavior's error path.
        _pendingOpen = null;
        Haptics.error();
        if (mounted) {
          setState(() => _open = !target);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
          );
        }
      }
    } catch (_) {
      _scheduleRetry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final m = widget.merchant;
    final theme = Theme.of(context);
    // Live order feed lives here (not just behind the Orders button) so a
    // new order is visible — and rings/vibrates — right on the home screen,
    // same provider merchant_orders_screen.dart uses.
    final orders = m.isApproved
        ? ref.watch(merchantOrdersProvider(m.id)).valueOrNull ?? const []
        : const <CustomerOrder>[];
    final incoming =
        orders.where((o) => _activeStatuses.contains(o.status)).toList();
    final now = DateTime.now();
    final ordersToday = orders.where((o) {
      final created = o.createdAt;
      return created != null &&
          created.year == now.year &&
          created.month == now.month &&
          created.day == now.day &&
          o.status != 'cancelled' &&
          o.status != 'rejected';
    }).toList();
    final revenueToday = ordersToday.fold<double>(0, (sum, o) => sum + o.total);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  m.vertical == 'grocery'
                      ? Icons.local_grocery_store_rounded
                      : Icons.restaurant_rounded,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(m.name, style: theme.textTheme.titleMedium),
                ),
                if (m.isApproved && m.rating > 0) ...[
                  const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
                  const SizedBox(width: 2),
                  Text(m.rating.toStringAsFixed(1),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ],
            ),
            if (m.address != null) ...[
              const SizedBox(height: 4),
              Text(m.address!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            if (m.isPending) ...[
              Row(
                children: [
                  Icon(Icons.hourglass_top_rounded,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.storePendingReview,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        Text(l.storePendingReviewBody,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ] else if (m.isRejected) ...[
              Row(
                children: [
                  Icon(Icons.block_rounded,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.storeRejected,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.error)),
                        if (m.rejectionReason != null)
                          Text(m.rejectionReason!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ] else
              Row(
                children: [
                  Text(_open ? l.merchantOpen : l.merchantClosed),
                  const Spacer(),
                  Switch(value: _open, onChanged: _toggle),
                ],
              ),
            if (m.isApproved) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _TodayStat(
                      label: l.merchantOrdersToday,
                      value: '${ordersToday.length}',
                    ),
                  ),
                  Expanded(
                    child: _TodayStat(
                      label: l.merchantRevenueToday,
                      value: 'NPR ${revenueToday.toStringAsFixed(0)}',
                    ),
                  ),
                ],
              ),
            ],
            if (incoming.isNotEmpty) ...[
              const Divider(height: 24),
              Row(
                children: [
                  Text(l.merchantIncomingOrders,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  _CountBadge(count: incoming.length),
                  const Spacer(),
                  TextButton(
                    onPressed: () =>
                        context.push(Routes.merchantOrders, extra: m),
                    child: Text(l.merchantViewAll),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final o in incoming.take(3)) _IncomingOrderTile(order: o),
            ],
            const Divider(height: 24),
            Row(
              children: [
                if (m.isApproved) ...[
                  Expanded(
                    child: Badge(
                      isLabelVisible: incoming.isNotEmpty,
                      label: Text('${incoming.length}'),
                      child: FilledButton.icon(
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: Text(l.merchantOrders),
                        onPressed: () =>
                            context.push(Routes.merchantOrders, extra: m),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.menu_book_rounded),
                    label: Text(l.merchantMenu),
                    onPressed: () =>
                        context.push(Routes.merchantMenu, extra: m),
                  ),
                ),
              ],
            ),
            if (m.isApproved) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.insights_rounded),
                      label: Text(l.storeAnalyticsAction),
                      onPressed: () =>
                          context.push(Routes.merchantAnalytics, extra: m),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.local_offer_rounded),
                      label: Text(l.storeOffersAction),
                      onPressed: () =>
                          context.push(Routes.merchantOffers, extra: m),
                    ),
                  ),
                ],
              ),
            ],
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
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$count',
        style: TextStyle(
            color: scheme.onPrimary, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}

/// One-line preview of a just-placed order on the home screen — enough to
/// glance at without leaving for the full Orders queue.
class _IncomingOrderTile extends StatelessWidget {
  const _IncomingOrderTile({required this.order});
  final CustomerOrder order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.notifications_active_rounded,
              size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('#${order.id.substring(0, 8)}',
                style: theme.textTheme.bodyMedium),
          ),
          Text('NPR ${order.total.toStringAsFixed(2)}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storefront_rounded,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
