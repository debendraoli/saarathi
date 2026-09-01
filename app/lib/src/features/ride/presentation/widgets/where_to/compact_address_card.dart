import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import 'address_line.dart';
import 'address_rail.dart';
import 'rail_button.dart';

/// Pickup/destination collapsed onto one connected block: a dot-and-flag
/// rail on the left, one compact line per point on the right, and a swap
/// button — the single biggest space saving over the old two-full-row
/// layout. Tapping a line still opens the same search screen as before;
/// stops (uncommon) render as extra rail segments rather than a separate
/// section.
class CompactAddressCard extends StatelessWidget {
  const CompactAddressCard({
    super.key,
    required this.pickupText,
    required this.resolvingPickup,
    required this.destText,
    required this.resolvingDest,
    required this.stops,
    required this.onPickupTap,
    required this.onDestTap,
    required this.onAddStop,
    required this.onRemoveStop,
    required this.onSave,
    required this.onClearDest,
  });

  final String pickupText;
  final bool resolvingPickup;
  final String? destText;
  final bool resolvingDest;
  final List<String> stops;
  final VoidCallback onPickupTap;
  final VoidCallback onDestTap;
  final VoidCallback? onAddStop;
  final ValueChanged<int> onRemoveStop;
  final VoidCallback? onSave;
  final VoidCallback? onClearDest;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AddressRail(scheme: scheme, stopCount: stops.length),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AddressLine(
                      text: pickupText,
                      isPlaceholder: false,
                      loading: resolvingPickup,
                      onTap: onPickupTap,
                    ),
                    for (var i = 0; i < stops.length; i++)
                      AddressLine(
                        text: stops[i],
                        isPlaceholder: false,
                        onTap: onAddStop ?? () {},
                        dim: true,
                        trailing: GestureDetector(
                          onTap: () => onRemoveStop(i),
                          child: Icon(Icons.close_rounded,
                              size: 16, color: scheme.outline),
                        ),
                      ),
                    AddressLine(
                      text: destText ?? l.searchAddressHint,
                      isPlaceholder: destText == null,
                      loading: resolvingDest,
                      onTap: onDestTap,
                      last: true,
                    ),
                  ],
                ),
              ),
              if (onSave != null || onClearDest != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (onClearDest != null)
                        RailButton(
                          icon: Icons.close_rounded,
                          tooltip: l.clearDestination,
                          onTap: onClearDest!,
                        ),
                      if (onSave != null)
                        RailButton(
                          icon: Icons.bookmark_add_outlined,
                          tooltip: l.saveAction,
                          onTap: onSave!,
                        ),
                    ],
                  ),
                ),
            ],
          ),
          // A labeled row, not another bare icon — "stops is missing" was the
          // exact feedback the icon-only version got, so this one spells
          // itself out even at compact height.
          if (onAddStop != null) ...[
            Divider(height: 14, color: scheme.outlineVariant),
            InkWell(
              onTap: onAddStop,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_location_alt_outlined,
                      size: 17, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    l.addStop,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
