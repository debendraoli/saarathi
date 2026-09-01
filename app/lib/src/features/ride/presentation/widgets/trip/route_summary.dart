import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../map_view.dart';

/// Pickup + destination addresses, always shown together — previously
/// pickup was fetched (`tripOriginLabelProvider`) but never actually
/// rendered anywhere in the live trip sheet, only in the post-trip rating
/// summary.
class RouteSummary extends StatelessWidget {
  const RouteSummary({super.key, required this.pickup, required this.dest});
  final AsyncValue<String?> pickup;
  final AsyncValue<String?> dest;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RoutePoint(
          icon: Icons.emoji_people_rounded,
          color: routeLineColor,
          value: pickup,
        ),
        const Padding(
          padding: EdgeInsets.only(left: 7),
          child: SizedBox(
            height: 14,
            child: VerticalDivider(width: 14, color: routeLineColor),
          ),
        ),
        _RoutePoint(
          icon: Icons.sports_score_rounded,
          color: routeLineColor,
          value: dest,
        ),
      ],
    );
  }
}

class _RoutePoint extends StatelessWidget {
  const _RoutePoint({
    required this.icon,
    required this.color,
    required this.value,
  });
  final IconData icon;
  final Color color;
  final AsyncValue<String?> value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A genuinely-still-loading fetch (no value yet) gets the progress bar;
    // once it resolves — even to null, i.e. no address found for that point
    // — show text instead, or that bar would look stuck forever. `.value`
    // (not `.value`) is deliberate: it also surfaces the last-known
    // value during a rebuild-triggered refetch, avoiding a flicker back to
    // "loading" for a point already resolved once.
    final loading = value.isLoading && !value.hasValue;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: loading
              ? SizedBox(
                  height: 14,
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    color: theme.colorScheme.outlineVariant,
                    backgroundColor: Colors.transparent,
                  ),
                )
              : Text(
                  value.value ?? AppL10n.of(context).addressUnavailable,
                  style: theme.textTheme.bodyMedium,
                ),
        ),
      ],
    );
  }
}
