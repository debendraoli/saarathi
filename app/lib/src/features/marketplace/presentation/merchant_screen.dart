import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../application/cart_controller.dart';
import '../data/marketplace_repository.dart';
import '../domain/models.dart';

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
          if (items.isEmpty) {
            return Center(child: Text(l.comingSoonBody));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _ItemTile(
              merchant: merchant,
              item: items[i],
              qty: cartForThis.lines[items[i].id]?.qty ?? 0,
            ),
          );
        },
      ),
      bottomNavigationBar: cartForThis.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () => context.push(Routes.checkout),
                  child: Text(
                    '${l.viewCart} · ${cartForThis.count} · NPR ${cartForThis.subtotal.toStringAsFixed(0)}',
                  ),
                ),
              ),
            ),
    );
  }
}

class _ItemTile extends ConsumerWidget {
  const _ItemTile(
      {required this.merchant, required this.item, required this.qty});
  final Merchant merchant;
  final MenuItem item;
  final int qty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.read(cartControllerProvider.notifier);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      title:
          Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        item.description ?? 'NPR ${item.price.toStringAsFixed(0)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: qty == 0
          ? OutlinedButton(
              onPressed: () => cart.add(
                item,
                merchantId: merchant.id,
                merchantName: merchant.name,
              ),
              child: Text('NPR ${item.price.toStringAsFixed(0)}'),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () => cart.decrement(item.id),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                ),
                Text('$qty',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                IconButton(
                  onPressed: () => cart.add(
                    item,
                    merchantId: merchant.id,
                    merchantName: merchant.name,
                  ),
                  icon: const Icon(Icons.add_circle_rounded),
                ),
              ],
            ),
    );
  }
}
