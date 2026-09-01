import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../application/trip_ws.dart';

/// Rider-only toggle: when on, [RiderLocationPublisher] starts posting their
/// live GPS so the driver sees it instead of the static pickup pin (see that
/// class's doc comment). Purely local UI state (`riderShareLocationProvider`)
/// — nothing is persisted, so this always starts off for a fresh trip.
class ShareLocationToggle extends ConsumerWidget {
  const ShareLocationToggle({super.key, required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sharing = ref.watch(riderShareLocationProvider(tripId));
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => ref
          .read(riderShareLocationProvider(tripId).notifier)
          .update((v) => !v),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              sharing
                  ? Icons.share_location_rounded
                  : Icons.location_off_rounded,
              color: sharing ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.shareLiveLocation,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    l.shareLiveLocationBody,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Switch(
              value: sharing,
              onChanged: (v) => ref
                  .read(riderShareLocationProvider(tripId).notifier)
                  .state = v,
            ),
          ],
        ),
      ),
    );
  }
}
