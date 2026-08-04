import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../data/marketplace_repository.dart';
import '../domain/models.dart';
import 'item_search_screen.dart';

enum MarketplaceKind { food, grocery }

/// Merchant discovery for a vertical (food / grocery), nearest first.
class MarketplaceScreen extends ConsumerWidget {
  const MarketplaceScreen({super.key, required this.kind});
  final MarketplaceKind kind;

  String get _vertical => kind == MarketplaceKind.food ? 'food' : 'grocery';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final title = kind == MarketplaceKind.food ? l.food : l.grocery;
    final merchants = ref.watch(merchantsProvider(_vertical));

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ItemSearchScreen(vertical: _vertical),
              ),
            ),
          ),
        ],
      ),
      body: merchants.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(merchantsProvider(_vertical)),
        ),
        data: (list) {
          if (list.isEmpty) {
            return _EmptyMerchants(kind: kind);
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(merchantsProvider(_vertical)),
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _MerchantCard(merchant: list[i]),
            ),
          );
        },
      ),
    );
  }
}

class _MerchantCard extends StatelessWidget {
  const _MerchantCard({required this.merchant});
  final Merchant merchant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.merchant, extra: merchant),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: scheme.primaryContainer,
                child: Icon(
                  merchant.vertical == 'grocery'
                      ? Icons.local_grocery_store_rounded
                      : Icons.restaurant_rounded,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      merchant.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded,
                            size: 15, color: Colors.amber),
                        Text(' ${merchant.rating.toStringAsFixed(1)}  ·  '),
                        Icon(
                          Icons.schedule_rounded,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        Text(' ${merchant.prepMins}m'),
                        if (merchant.distanceKm != null)
                          Text(
                              '  ·  ${merchant.distanceKm!.toStringAsFixed(1)} km'),
                      ],
                    ),
                    if (!merchant.isOpen)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Closed',
                          style: TextStyle(color: scheme.error, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyMerchants extends StatelessWidget {
  const _EmptyMerchants({required this.kind});
  final MarketplaceKind kind;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              kind == MarketplaceKind.food
                  ? Icons.restaurant_rounded
                  : Icons.local_grocery_store_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              l.comingSoonTitle,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(l.comingSoonBody, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
