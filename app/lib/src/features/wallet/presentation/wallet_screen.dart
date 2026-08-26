import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../data/wallet_repository.dart';
import '../domain/models.dart';
import 'topup_screen.dart';

/// Balance + top-up for whichever role is currently active — rider prepaid
/// credits (pay for rides/orders) or driver prepaid credits (fund the
/// per-ride commission draw). Same screen, different copy/endpoint.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final isDriver = ref.watch(authControllerProvider).mode == AppMode.driver;
    final async = ref.watch(walletBalanceProvider);

    return Scaffold(
      appBar: AppBar(title: Text(isDriver ? l.creditsTitle : l.walletTitle)),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(walletBalanceProvider),
        ),
        data: (wallet) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(walletBalanceProvider),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.currentBalance,
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 4),
                      Text(
                        'NPR ${wallet.balance.toStringAsFixed(2)}',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isDriver ? l.creditsBody : l.walletBody,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () async {
                          final done = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) => const TopupScreen(),
                            ),
                          );
                          if (done == true) {
                            ref.invalidate(walletBalanceProvider);
                          }
                        },
                        icon: const Icon(Icons.add_rounded),
                        label: Text(l.topUp),
                      ),
                    ],
                  ),
                ),
              ),
              if (wallet.transactions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(l.recentActivity,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final txn in wallet.transactions) _TxnTile(txn: txn),
                    ],
                  ),
                ),
              ] else if (!isDriver) ...[
                const SizedBox(height: 40),
                Center(
                  child: Text(l.noActivityYet,
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TxnTile extends StatelessWidget {
  const _TxnTile({required this.txn});
  final WalletTxn txn;

  // An unrecognized type (any new backend txn kind — a refund, a promo
  // credit) fell all the way through to an ambiguous swap icon regardless
  // of its actual amount sign, giving no visual cue at all for something
  // this tile otherwise already colors by sign. Fall back to the same
  // sign-based direction instead.
  IconData get _icon => switch (txn.type) {
        'topup' => Icons.add_circle_outline_rounded,
        'ride_charge' || 'order_charge' => Icons.remove_circle_outline_rounded,
        _ => txn.amount >= 0
            ? Icons.add_circle_outline_rounded
            : Icons.remove_circle_outline_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final positive = txn.amount >= 0;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(_icon, color: scheme.onSurfaceVariant),
      title: Text(txn.type.replaceAll('_', ' ')),
      subtitle: txn.createdAt == null ? null : Text(_fmtDate(txn.createdAt!)),
      trailing: Text(
        '${positive ? '+' : ''}NPR ${txn.amount.toStringAsFixed(2)}',
        style: TextStyle(
          color: positive ? scheme.primary : scheme.error,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
