import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../domain/rating_tags.dart';

/// Star rating + the feedback tags picked, returned to the caller on submit.
class RatingResult {
  const RatingResult(this.stars, this.tags);
  final int stars;
  final List<String> tags;
}

/// A just-finished trip's summary, shown above the star picker so the rider
/// isn't rating in a vacuum — which trip, where it went, what it cost.
class TripSummary {
  const TripSummary({this.pickupLabel, this.destLabel, this.fare});
  final String? pickupLabel;
  final String? destLabel;
  final double? fare;
}

Future<RatingResult?> showRatingSheet(
  BuildContext context, {
  required RatingContext ratingContext,
  TripSummary? summary,
}) {
  return showModalBottomSheet<RatingResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _RatingSheet(ratingContext: ratingContext, summary: summary),
  );
}

class _RatingSheet extends StatefulWidget {
  const _RatingSheet({required this.ratingContext, this.summary});
  final RatingContext ratingContext;
  final TripSummary? summary;

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  int _stars = 5;
  final _tags = <String>{};

  /// Star count changed → the tag vocabulary (positive vs negative) changes
  /// too, so anything picked from the other list no longer applies.
  void _setStars(int stars) {
    setState(() {
      _stars = stars;
      _tags.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final media = MediaQuery.of(context);
    // Clear the keyboard (viewInsets) and the system nav bar (padding) —
    // without the latter, the Submit button sits under the gesture nav bar.
    final bottom = media.viewInsets.bottom + media.padding.bottom;
    final (positive, negative) = ratingTagsFor(l, widget.ratingContext);
    final tags = _stars >= 4 ? positive : negative;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.rateTrip,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (widget.summary != null) ...[
            const SizedBox(height: 14),
            _TripSummaryCard(summary: widget.summary!),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final filled = i < _stars;
              return IconButton(
                iconSize: 40,
                onPressed: () => _setStars(i + 1),
                icon: Icon(
                  filled ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: filled
                      ? Colors.amber
                      : Theme.of(context).colorScheme.outline,
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in tags)
                FilterChip(
                  label: Text(tag),
                  selected: _tags.contains(tag),
                  onSelected: (selected) => setState(() {
                    if (selected) {
                      _tags.add(tag);
                    } else {
                      _tags.remove(tag);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _tags.isEmpty
                ? null
                : () => Navigator.pop(
                      context,
                      RatingResult(_stars, _tags.toList()),
                    ),
            child: Text(l.submit),
          ),
        ],
      ),
    );
  }
}

class _TripSummaryCard extends StatelessWidget {
  const _TripSummaryCard({required this.summary});
  final TripSummary summary;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary.pickupLabel != null)
            _SummaryRow(
              icon: Icons.emoji_people_rounded,
              iconColor: scheme.primary,
              label: l.pickup,
              value: summary.pickupLabel!,
            ),
          if (summary.pickupLabel != null && summary.destLabel != null)
            const SizedBox(height: 8),
          if (summary.destLabel != null)
            _SummaryRow(
              icon: Icons.sports_score_rounded,
              iconColor: scheme.secondary,
              label: l.destination,
              value: summary.destLabel!,
            ),
          if (summary.fare != null) ...[
            Divider(height: 20, color: scheme.outlineVariant),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(l.fare, style: theme.textTheme.bodyMedium),
                Text(
                  'NPR ${summary.fare!.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              Text(value, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
