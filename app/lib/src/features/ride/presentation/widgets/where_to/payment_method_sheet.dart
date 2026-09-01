import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../../../shared/widgets/currency_chip.dart';
import '../../../../wallet/data/wallet_repository.dart';
import 'payment_method_tile.dart';

/// Payment method picker — cash or wallet, with the live wallet balance
/// shown right on the wallet row instead of a separate hint line.
void showPaymentMethodSheet(
  BuildContext context, {
  required String payment,
  required ValueChanged<String> onPayment,
}) {
  final l = AppL10n.of(context);
  showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Theme.of(sheetContext).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              l.paymentMethodTitle,
              style: Theme.of(sheetContext)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            PaymentMethodTile(
              icon: Icons.payments_rounded,
              label: l.paymentCash,
              selected: payment == 'cash',
              onTap: () {
                onPayment('cash');
                Navigator.pop(sheetContext);
              },
            ),
            Consumer(
              builder: (context, ref, _) {
                final wallet = ref.watch(walletBalanceProvider);
                return PaymentMethodTile(
                  icon: Icons.account_balance_wallet_rounded,
                  label: l.paymentWallet,
                  trailing: wallet.when(
                    loading: () => const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    error: (_, __) => null,
                    data: (w) => Text(
                      '$currencySymbol ${w.balance.toStringAsFixed(0)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  selected: payment == 'wallet',
                  onTap: () {
                    onPayment('wallet');
                    Navigator.pop(sheetContext);
                  },
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
