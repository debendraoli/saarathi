import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shared/widgets/currency_chip.dart';
import '../../../../../shared/widgets/skeleton.dart';
import '../../../domain/models.dart';

/// A compact selectable vehicle-class chip (icon + label + price in one tight
/// column), Yango/Pathao/inDrive style — replaces the old taller card so a
/// row of these takes noticeably less vertical space and leaves more of the
/// sheet's height to the map.
class VehicleChip extends StatelessWidget {
  const VehicleChip({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.price,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;

  /// Live price for this class — null before pickup/destination are set.
  final AsyncValue<FareEstimate>? price;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Selected = solid inverse fill (reads as "chosen" at a glance, like the
    // reference apps); unselected = a quiet neutral chip.
    final fg = selected ? scheme.onInverseSurface : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.inverseSurface : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  color: fg,
                ),
              ),
              if (price != null) ...[
                const SizedBox(height: 1),
                price!.when(
                  // A shimmer the size of the eventual price text, not a
                  // spinner — the number then lands in the space already
                  // held for it instead of popping the layout.
                  loading: () => const SkeletonBox(width: 40, height: 12),
                  error: (_, __) =>
                      Text('—', style: TextStyle(fontSize: 11.5, color: fg)),
                  data: (fare) => Text(
                    '$currencySymbol ${fare.finalFare.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
