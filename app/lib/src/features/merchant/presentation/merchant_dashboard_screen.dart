import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../../marketplace/domain/models.dart';
import '../data/merchant_repository.dart';

/// The merchant owner's home: the store(s) they run, an open/closed toggle, and
/// entries into the live order queue and menu management.
class MerchantDashboardScreen extends ConsumerWidget {
  const MerchantDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(myMerchantsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.merchantStore)),
      body: async.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(myMerchantsProvider),
        ),
        data: (merchants) {
          if (merchants.isEmpty) {
            return _EmptyState(message: l.merchantNoStore);
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myMerchantsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: merchants.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _StoreCard(merchant: merchants[i]),
            ),
          );
        },
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
  bool _busy = false;

  Future<void> _toggle(bool value) async {
    setState(() => _busy = true);
    try {
      final now =
          await ref.read(merchantRepositoryProvider).setOpen(widget.merchant.id, value);
      if (mounted) setState(() => _open = now);
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
    final m = widget.merchant;
    final theme = Theme.of(context);
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
              ],
            ),
            if (m.address != null) ...[
              const SizedBox(height: 4),
              Text(m.address!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Text(_open ? l.merchantOpen : l.merchantClosed),
                const Spacer(),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Switch(value: _open, onChanged: _toggle),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.receipt_long_rounded),
                    label: Text(l.merchantOrders),
                    onPressed: () =>
                        context.push(Routes.merchantOrders, extra: m),
                  ),
                ),
                const SizedBox(width: 12),
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
          ],
        ),
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
