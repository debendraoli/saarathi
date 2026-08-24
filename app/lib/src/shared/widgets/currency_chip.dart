import 'package:flutter/material.dart';

/// Devanagari "Ru" — Nepal's actual currency shorthand in Nepali script,
/// used in place of the "NPR" ISO code wherever a fare/price is the focal
/// element of the UI (request sheet, vehicle cards) rather than a plain
/// data table.
const String currencySymbol = 'रु';

/// A rounded pill pairing the currency symbol with an amount — replaces a
/// bare "NPR 123" text run wherever the price is the visual focus of a
/// card or row, so it reads as one deliberate unit instead of a plain label.
class CurrencyChip extends StatelessWidget {
  const CurrencyChip({
    super.key,
    required this.amount,
    this.large = false,
  });

  /// Already-formatted amount text (caller decides decimals/rounding).
  final String amount;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 16 : 10,
        vertical: large ? 8 : 4,
      ),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            currencySymbol,
            style: (large ? textTheme.titleMedium : textTheme.labelLarge)
                ?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onPrimaryContainer.withValues(alpha: 0.75),
            ),
          ),
          SizedBox(width: large ? 6 : 3),
          Text(
            amount,
            style: (large ? textTheme.headlineSmall : textTheme.titleMedium)
                ?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onPrimaryContainer,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
