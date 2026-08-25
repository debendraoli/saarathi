import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../core/router/app_router.dart';
import '../../features/wallet/data/wallet_repository.dart';

/// Shown wherever "wallet" is an available payment method — wallet payments
/// actually debit now, so surface whether the balance covers the amount
/// *before* the user commits, instead of finding out only after tapping
/// confirm and hitting a rejection.
class WalletBalanceHint extends ConsumerWidget {
  const WalletBalanceHint({super.key, required this.amount});
  final double amount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(walletBalanceProvider);
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (wallet) {
        final low = wallet.balance < amount;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Icon(
                low
                    ? Icons.error_outline_rounded
                    : Icons.check_circle_outline_rounded,
                size: 16,
                color: low ? scheme.error : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  low
                      ? l.walletBalanceLow
                      : l.walletBalanceShort(wallet.balance.toStringAsFixed(0)),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: low ? scheme.error : scheme.onSurfaceVariant,
                      ),
                ),
              ),
              if (low)
                TextButton(
                  onPressed: () => context.push(Routes.topup),
                  child: Text(l.topUp),
                ),
            ],
          ),
        );
      },
    );
  }
}
