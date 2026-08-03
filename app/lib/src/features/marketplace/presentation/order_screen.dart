import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
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

    return Scaffold(
      appBar: AppBar(
        title: Text(l.yourOrder),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go(Routes.home),
        ),
      ),
      body: order.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(orderProvider(orderId)),
        ),
        data: (o) {
          final cancelled = o.status == 'cancelled' || o.status == 'rejected';
          final stepIndex = _steps.indexOf(o.status);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                o.merchantName,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
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
                  onPressed: () => context.push('${Routes.trip}/${o.tripId}'),
                  icon: const Icon(Icons.map_rounded),
                  label: Text(l.trackCourier),
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
              _row(l.deliveryFee, o.deliveryFee),
              _row(l.total, o.total, bold: true),
            ],
          );
        },
      ),
    );
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
