import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart' show ApiException;
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../../ride/application/ride_controller.dart';
import '../../ride/data/ride_repository.dart';
import '../../ride/domain/rating_tags.dart';
import '../../ride/presentation/widgets/mini_route_map.dart';
import '../../ride/presentation/widgets/rating_sheet.dart';
import '../../support/presentation/support_chat_screen.dart';
import '../data/marketplace_repository.dart';

const _steps = <String>[
  'placed',
  'confirmed',
  'preparing',
  'ready',
  'picked_up',
  'delivered',
];

class OrderScreen extends ConsumerWidget {
  const OrderScreen({super.key, required this.orderId});
  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final order = ref.watch(orderProvider(orderId));
    final stale = ref.watch(orderStaleProvider(orderId));

    // Reached two different ways: `context.go` from checkout (replacing the
    // stack so a placed order can't be re-submitted from history — nothing
    // to pop back to there, so leaving goes to Home) and `context.push`
    // from a real caller (Activities' order history) that should be popped
    // back to instead of blown past to Home.
    void leave() {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Routes.home);
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.yourOrder),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: leave,
          ),
        ),
        body: Column(
          children: [
            if (stale) const StaleBanner(),
            Expanded(
              child: order.when(
                loading: () => const LoadingView(),
                error: (_, __) => ErrorRetry(
                  message: l.errorNetwork,
                  onRetry: () => retryOrderPoll(ref, orderId),
                ),
                data: (o) {
                  final cancelled =
                      o.status == 'cancelled' || o.status == 'rejected';
                  final stepIndex = _steps.indexOf(o.status);
                  return ListView(
                    padding: EdgeInsets.fromLTRB(
                        16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
                    children: [
                      Text(
                        o.merchantName,
                        style: Theme.of(
                          context,
                        )
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 16),
                      if (cancelled)
                        _Banner(
                          icon: Icons.cancel_rounded,
                          label: l.orderCancelled,
                          color: Theme.of(context).colorScheme.error,
                        )
                      else
                        Column(
                          children: [
                            for (var i = 0; i < _steps.length; i++)
                              _Step(
                                label: _stepLabel(l, _steps[i]),
                                done: i <= stepIndex,
                                current: i == stepIndex,
                                last: i == _steps.length - 1,
                              ),
                          ],
                        ),
                      const SizedBox(height: 16),
                      if (o.tripId != null && o.isActive)
                        FilledButton.icon(
                          onPressed: () =>
                              context.push('${Routes.trip}/${o.tripId}'),
                          icon: const Icon(Icons.map_rounded),
                          label: Text(l.trackCourier),
                        ),
                      // Matches the backend's own window exactly
                      // (marketplace.rs `update_order_status`): only while
                      // the merchant hasn't started preparing it yet. There
                      // was previously no way to reach this from the app at
                      // all — a customer who placed an order by mistake had
                      // no in-app path to cancel it.
                      if (o.status == 'placed' || o.status == 'confirmed')
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton.icon(
                            onPressed: () => _cancelOrder(context, ref),
                            icon: const Icon(Icons.close_rounded),
                            label: Text(l.cancelOrder),
                          ),
                        ),
                      if (o.status == 'delivered' &&
                          o.tripId != null &&
                          !o.rated)
                        FilledButton.icon(
                          onPressed: () =>
                              _rateCourier(context, ref, o.tripId!),
                          icon: const Icon(Icons.star_rounded),
                          label: Text(l.rateCourierAction),
                        ),
                      if (o.status == 'delivered' && !o.merchantRated)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton.icon(
                            onPressed: () => _rateMerchant(context, ref),
                            icon: const Icon(Icons.storefront_rounded),
                            label: Text(l.rateRestaurantAction),
                          ),
                        ),
                      // Only once a courier's actually been dispatched — the
                      // pickup point here is that courier's own trip origin
                      // (the merchant), not something this order carries
                      // itself; nothing to show before dispatch.
                      if (o.tripId != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _CourierRouteMap(tripId: o.tripId!),
                        ),
                      const Divider(height: 32),
                      for (final item in o.items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: Text('${item.qty}×'),
                          title: Text(item.name),
                          trailing: Text(
                            'NPR ${(item.unitPrice * item.qty).toStringAsFixed(0)}',
                          ),
                        ),
                      const Divider(),
                      _row(l.subtotal, o.subtotal),
                      if (o.discountAmount > 0)
                        _row(l.orderDiscount, -o.discountAmount),
                      _row(l.deliveryFee, o.deliveryFee),
                      _row(l.total, o.total, bold: true),
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        onPressed: () => context.push(
                          Routes.support,
                          extra: SupportContextArgs(orderId: o.id),
                        ),
                        icon: const Icon(Icons.support_agent_rounded),
                        label: Text(l.getHelp),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rateCourier(
      BuildContext context, WidgetRef ref, String tripId) async {
    final result = await showRatingSheet(
      context,
      ratingContext: RatingContext.senderRatesCourier,
    );
    if (result == null) return;
    try {
      await ref
          .read(rideRepositoryProvider)
          .rate(tripId, result.stars, tags: result.tags);
    } catch (_) {/* non-blocking */}
    ref.invalidate(orderProvider(orderId));
  }

  Future<void> _rateMerchant(BuildContext context, WidgetRef ref) async {
    final result = await showRatingSheet(
      context,
      ratingContext: RatingContext.customerRatesMerchant,
    );
    if (result == null) return;
    final repo = ref.read(marketplaceRepositoryProvider);
    try {
      await repo.rateMerchant(orderId, result.stars, tags: result.tags);
    } catch (_) {/* non-blocking */}
    await repo.cancelReviewReminder(orderId);
    ref.invalidate(orderProvider(orderId));
  }

  Future<void> _cancelOrder(BuildContext context, WidgetRef ref) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.cancelOrder),
        content: Text(l.cancelOrderConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.cancelOrder),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(marketplaceRepositoryProvider).cancelOrder(orderId);
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.isNetwork ? l.errorNetwork : e.message)),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.errorGeneric)));
      }
    }
    ref.invalidate(orderProvider(orderId));
  }

  Widget _row(String label, double amount, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: bold ? const TextStyle(fontWeight: FontWeight.w800) : null,
            ),
            Text(
              'NPR ${amount.toStringAsFixed(0)}',
              style: bold ? const TextStyle(fontWeight: FontWeight.w800) : null,
            ),
          ],
        ),
      );

  String _stepLabel(AppL10n l, String s) {
    switch (s) {
      case 'placed':
        return l.orderPlaced;
      case 'confirmed':
        return l.orderConfirmed;
      case 'preparing':
        return l.orderPreparing;
      case 'ready':
        return l.orderReady;
      case 'picked_up':
        return l.orderPickedUp;
      default:
        return l.orderDelivered;
    }
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.label,
    required this.done,
    required this.current,
    required this.last,
  });
  final String label;
  final bool done;
  final bool current;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = done ? scheme.primary : scheme.outlineVariant;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Icon(
                done ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: color,
                size: 22,
              ),
              if (!last) Expanded(child: Container(width: 2, color: color)),
            ],
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              label,
              style: TextStyle(
                fontWeight: current ? FontWeight.w800 : FontWeight.w500,
                color: done ? null : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The courier's route (merchant → this order's delivery address), reusing
/// the trip's own origin/dest — an order carries no coordinates of its own.
/// Quietly renders nothing while loading/on error rather than a spinner or
/// error banner; this is a secondary detail, not the point of the screen.
class _CourierRouteMap extends ConsumerWidget {
  const _CourierRouteMap({required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trip = ref.watch(tripDetailsProvider(tripId)).value;
    if (trip == null) return const SizedBox.shrink();
    return MiniRouteMap(origin: trip.origin, dest: trip.dest);
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}
