import 'package:flutter/material.dart';

import '../haptics.dart';
import 'currency_chip.dart';

/// The big −/price/+ control for naming a fare (bid-mode booking, driver
/// counters, mid-auction "raise the ask"). Steps in NPR 10 increments and
/// clamps to [min, max] — never lets the caller submit a value the backend
/// would reject anyway.
class FareStepper extends StatelessWidget {
  const FareStepper({
    super.key,
    required this.amount,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 10,
    this.caption,
  });

  final double amount;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final String? caption;

  void _bump(double delta) {
    final next = (amount + delta).clamp(min, max);
    if (next != amount) {
      Haptics.tap();
      onChanged(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _StepButton(
              icon: Icons.remove_rounded,
              onTap: amount <= min ? null : () => _bump(-step),
            ),
            SizedBox(
              width: 140,
              child: Center(
                child: CurrencyChip(
                  amount: amount.toStringAsFixed(0),
                  large: true,
                ),
              ),
            ),
            _StepButton(
              icon: Icons.add_rounded,
              onTap: amount >= max ? null : () => _bump(step),
            ),
          ],
        ),
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(
            caption!,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Material(
      color: enabled ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            icon,
            color: enabled ? scheme.onPrimaryContainer : scheme.outline,
          ),
        ),
      ),
    );
  }
}
