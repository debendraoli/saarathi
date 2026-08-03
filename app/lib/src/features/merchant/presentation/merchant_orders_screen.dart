import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../marketplace/domain/models.dart';
import '../data/merchant_repository.dart';

/// Live order queue for one store. Polls every few seconds and lets the owner
/// accept → prepare → mark ready (which hands off to a courier).
class MerchantOrdersScreen extends ConsumerStatefulWidget {
  const MerchantOrdersScreen({super.key, required this.merchant});
  final Merchant merchant;

  @override
  ConsumerState<MerchantOrdersScreen> createState() =>
      _MerchantOrdersScreenState();
}

class _MerchantOrdersScreenState extends ConsumerState<MerchantOrdersScreen> {
  String _filter = 'active';

  bool _matches(CustomerOrder o) {
    switch (_filter) {
      case 'active':
        return o.isActive;
      case 'new':
        return o.status == 'placed';
      case 'preparing':
        return o.status == 'confirmed' || o.status == 'preparing';
      case 'ready':
        return const {'ready', 'picked_up', 'delivered'}.contains(o.status);
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final async = ref.watch(merchantOrdersProvider(widget.merchant.id));

    final filters = <(String, String)>[
      ('active', l.merchantFilterActive),
      ('new', l.merchantFilterNew),
      ('preparing', l.merchantFilterPreparing),
      ('ready', l.merchantFilterReady),
      ('all', l.merchantFilterAll),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(widget.merchant.name)),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (final f in filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _filter == f.$1,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const LoadingView(),
              error: (_, __) => ErrorRetry(
                message: l.errorNetwork,
                onRetry: () =>
                    ref.invalidate(merchantOrdersProvider(widget.merchant.id)),
              ),
              data: (orders) {
                final shown = orders.where(_matches).toList();
                if (shown.isEmpty) {
                  return Center(child: Text(l.merchantNoOrders));
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _OrderCard(
                    order: shown[i],
                    merchantId: widget.merchant.id,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderCard extends ConsumerStatefulWidget {
  const _OrderCard({required this.order, required this.merchantId});
  final CustomerOrder order;
  final String merchantId;

  @override
  ConsumerState<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends ConsumerState<_OrderCard> {
  bool _busy = false;

  /// The primary forward action for this status, or null if the courier owns it.
  (String, String)? _nextAction(AppL10n l) {
    switch (widget.order.status) {
      case 'placed':
        return ('confirmed', l.merchantAccept);
      case 'confirmed':
        return ('preparing', l.merchantStartPreparing);
      case 'preparing':
        return ('ready', l.merchantMarkReady);
      default:
        return null;
    }
  }

  Future<void> _advance(String status) async {
    setState(() => _busy = true);
    try {
      await ref.read(merchantRepositoryProvider).advance(widget.order.id, status);
      ref.invalidate(merchantOrdersProvider(widget.merchantId));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final o = widget.order;
    final theme = Theme.of(context);
    final next = _nextAction(l);
    final canReject = o.status == 'placed' || o.status == 'confirmed';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '#${o.id.substring(0, 8)}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _StatusChip(status: o.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'NPR ${o.total.toStringAsFixed(2)} · ${_time(o.createdAt)}',
              style: theme.textTheme.bodySmall,
            ),
            _Items(orderId: o.id),
            if (next != null || canReject) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (canReject)
                    OutlinedButton(
                      onPressed: _busy ? null : () => _advance('rejected'),
                      child: Text(l.merchantReject),
                    ),
                  const Spacer(),
                  if (next != null)
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      onPressed: _busy ? null : () => _advance(next.$1),
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(next.$2),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _time(DateTime? t) {
    if (t == null) return '';
    final local = t.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Lazily loads and shows the line items for an order (once per mount).
class _Items extends ConsumerStatefulWidget {
  const _Items({required this.orderId});
  final String orderId;

  @override
  ConsumerState<_Items> createState() => _ItemsState();
}

class _ItemsState extends ConsumerState<_Items> {
  late final Future<CustomerOrder> _future =
      ref.read(merchantRepositoryProvider).orderDetail(widget.orderId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CustomerOrder>(
      future: _future,
      builder: (context, snap) {
        final items = snap.data?.items ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final it in items)
                Text('${it.qty}× ${it.name}',
                    style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, _) = switch (status) {
      'placed' => (scheme.primary, 0),
      'confirmed' || 'preparing' => (scheme.tertiary, 0),
      'ready' || 'picked_up' => (scheme.secondary, 0),
      'delivered' => (Colors.green, 0),
      _ => (scheme.error, 0),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
