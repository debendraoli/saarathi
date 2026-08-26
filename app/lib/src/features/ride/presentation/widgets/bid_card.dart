import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../../shared/image_url.dart';
import '../../../../shared/widgets/swipe_to_confirm.dart';
import '../../domain/models.dart';

/// One live bid in the rider's auction list — driver identity, price, and a
/// swipe-to-accept action (accepting is binding: it assigns the trip
/// immediately, consistent with every other committing action in the app).
class BidCard extends StatelessWidget {
  const BidCard({
    super.key,
    required this.bid,
    required this.onAccept,
    this.busy = false,
  });

  final Bid bid;
  final VoidCallback onAccept;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final url = asImageUrl(bid.photoUrl);
    final initials = (bid.name == null || bid.name!.trim().isEmpty)
        ? '?'
        : bid.name!
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((s) => s[0].toUpperCase())
            .join();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundImage:
                      url != null ? CachedNetworkImageProvider(url) : null,
                  backgroundColor: scheme.secondaryContainer,
                  child: url == null
                      ? Text(
                          initials,
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bid.name?.isNotEmpty == true ? bid.name! : '—',
                        style: textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        [
                          if (bid.rating != null)
                            '★ ${bid.rating!.toStringAsFixed(1)}',
                          if (bid.vehicleLabel.isNotEmpty) bid.vehicleLabel,
                          if (bid.kind == 'counter')
                            AppL10n.of(context).bidCountered,
                        ].join(' · '),
                        style: textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Text(
                  'NPR ${bid.amount.toStringAsFixed(0)}',
                  style: textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SwipeToConfirm(
              label: AppL10n.of(context).accept,
              busy: busy,
              onConfirmed: onAccept,
              color: Colors.green.shade600,
            ),
          ],
        ),
      ),
    );
  }
}
