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
          // Flatten header + category sections + items into one bounded list.
          final rows = <Widget>[_Header(merchant: merchant)];
          if (items.isEmpty) {
            rows.add(Padding(
              padding: const EdgeInsets.all(40),
              child: Center(child: Text(l.comingSoonBody)),
            ));
          }
          for (final entry in grouped.entries) {
            rows.add(_CategoryHeader(entry.key));
            for (final it in entry.value) {
              rows.add(_ItemCard(
                merchant: merchant,
                item: it,
                qty: cartForThis.lines[it.id]?.qty ?? 0,
              ));
            }
          }
          rows.add(const SizedBox(height: 8));
          return ListView.builder(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 16,
            ),
            itemCount: rows.length,
            itemBuilder: (_, i) => rows[i],
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

class _ItemCard extends ConsumerWidget {
  const _ItemCard(
      {required this.merchant, required this.item, required this.qty});
  final Merchant merchant;
  final MenuItem item;
  final int qty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.read(cartControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    void add() =>
        cart.add(item, merchantId: merchant.id, merchantName: merchant.name);

    return ListTile(
      onTap: qty == 0 ? add : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _ItemThumb(imageUrl: item.imageUrl, vertical: merchant.vertical),
      title: Text(
        item.name,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.description != null && item.description!.isNotEmpty)
            Text(
              item.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 4),
          Text(
            'NPR ${item.price.toStringAsFixed(0)}',
            style:
                TextStyle(fontWeight: FontWeight.w800, color: scheme.primary),
          ),
        ],
      ),
      trailing: _QtyControl(
        qty: qty,
        onAdd: add,
        onRemove: () => cart.decrement(item.id),
      ),
    );
  }
}

/// Square item photo with a graceful icon fallback while/if the image fails.
class _ItemThumb extends StatelessWidget {
  const _ItemThumb({required this.imageUrl, required this.vertical});
  final String? imageUrl;
  final String vertical;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallbackIcon = vertical == 'grocery'
        ? Icons.local_grocery_store_rounded
        : Icons.restaurant_menu_rounded;
    final placeholder = Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(fallbackIcon, color: scheme.onSurfaceVariant),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 64,
        height: 64,
        child: imageUrl == null
            ? placeholder
            : Image.network(
                imageUrl!,
                fit: BoxFit.cover,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : placeholder,
                errorBuilder: (_, __, ___) => placeholder,
              ),
      ),
    );
  }
}

class _QtyControl extends StatelessWidget {
  const _QtyControl(
      {required this.qty, required this.onAdd, required this.onRemove});
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (qty == 0) {
      return OutlinedButton(
        onPressed: onAdd,
        // Finite width overrides the global full-width button theme so the
        // item text keeps its space.
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 38),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
        child: Text(AppL10n.of(context).addToCart),
      );
    }
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
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: onRemove,
            icon: const Icon(Icons.remove_rounded, size: 20),
          ),
          Text('$qty', style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 20),
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
