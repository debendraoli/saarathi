import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../application/cart_controller.dart';
import '../data/marketplace_repository.dart';
import '../domain/models.dart';

/// Merchant catalogue: a header with rating/prep/distance, the menu grouped by
/// category, and a sticky cart bar.
class MerchantScreen extends ConsumerWidget {
  const MerchantScreen({super.key, required this.merchant});
  final Merchant merchant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final detail = ref.watch(merchantDetailProvider(merchant.id));
    final cart = ref.watch(cartControllerProvider);
    final cartForThis =
        cart.merchantId == merchant.id ? cart : const CartState();

    return Scaffold(
      appBar: AppBar(title: Text(merchant.name)),
      body: detail.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(merchantDetailProvider(merchant.id)),
        ),
        data: (data) {
          final items = data.$2;
          final grouped = <String, List<MenuItem>>{};
          for (final it in items) {
            grouped.putIfAbsent(it.category ?? l.merchantMenu, () => []).add(it);
          }
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _Header(merchant: merchant)),
              if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text(l.comingSoonBody)),
                ),
              for (final entry in grouped.entries) ...[
                SliverToBoxAdapter(child: _CategoryHeader(entry.key)),
                SliverList.builder(
                  itemCount: entry.value.length,
                  itemBuilder: (_, i) => _ItemRow(
                    merchant: merchant,
                    item: entry.value[i],
                    qty: cartForThis.lines[entry.value[i].id]?.qty ?? 0,
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          );
        },
      ),
      bottomNavigationBar: cartForThis.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () => context.push(Routes.checkout),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CartBadge(count: cartForThis.count),
                      Text(l.viewCart,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('NPR ${cartForThis.subtotal.toStringAsFixed(0)}',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.merchant});
  final Merchant merchant;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: scheme.primaryContainer,
                child: Icon(
                  merchant.vertical == 'grocery'
                      ? Icons.local_grocery_store_rounded
                      : Icons.restaurant_rounded,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(merchant.name,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    if (merchant.address != null)
                      Text(merchant.address!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(
                icon: Icons.star_rounded,
                label: merchant.rating.toStringAsFixed(1),
                color: Colors.amber.shade800,
              ),
              _InfoChip(
                icon: Icons.schedule_rounded,
                label: '${merchant.prepMins} min',
              ),
              if (merchant.distanceKm != null)
                _InfoChip(
                  icon: Icons.place_rounded,
                  label: '${merchant.distanceKm!.toStringAsFixed(1)} km',
                ),
              _InfoChip(
                icon: merchant.isOpen
                    ? Icons.check_circle_rounded
                    : Icons.cancel_rounded,
                label: merchant.isOpen ? l.merchantOpen : l.merchantClosed,
                color: merchant.isOpen ? Colors.green.shade700 : scheme.error,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: c),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: c, fontWeight: FontWeight.w600, fontSize: 12.5)),
        ],
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _ItemRow extends ConsumerWidget {
  const _ItemRow(
      {required this.merchant, required this.item, required this.qty});
  final Merchant merchant;
  final MenuItem item;
  final int qty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.read(cartControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.restaurant_menu_rounded,
                color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                if (item.description != null &&
                    item.description!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(item.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
                const SizedBox(height: 6),
                Text('NPR ${item.price.toStringAsFixed(0)}',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: scheme.primary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _QtyControl(merchant: merchant, item: item, qty: qty, cart: cart),
        ],
      ),
    );
  }
}

class _QtyControl extends StatelessWidget {
  const _QtyControl({
    required this.merchant,
    required this.item,
    required this.qty,
    required this.cart,
  });
  final Merchant merchant;
  final MenuItem item;
  final int qty;
  final CartController cart;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    if (qty == 0) {
      return OutlinedButton(
        onPressed: () =>
            cart.add(item, merchantId: merchant.id, merchantName: merchant.name),
        child: Text(l.addToCart),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => cart.decrement(item.id),
            icon: const Icon(Icons.remove_rounded),
          ),
          Text('$qty', style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => cart.add(item,
                merchantId: merchant.id, merchantName: merchant.name),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

class _CartBadge extends StatelessWidget {
  const _CartBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.onPrimary.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$count',
          style: const TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}
