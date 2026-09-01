import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../../core/router/app_router.dart';
import '../../../../comms/presentation/call_screen.dart';
import '../../../domain/models.dart';
import 'trip_widgets_shared.dart';

/// Collapsed-state counterpart identity: avatar, name, rating, and a
/// Counterpart identity, plus the trip's one chat button and one call
/// button (previously there were two call buttons — a second, separate one
/// floating over the map — merged into just this one). The call button
/// opens the masked-in-app-vs-direct-dial picker; direct dial is unavailable
/// (button hidden) until `phone` is non-null (trip not yet active, or
/// already finished).
class CounterpartRow extends StatelessWidget {
  const CounterpartRow({
    super.key,
    required this.person,
    required this.tripId,
    this.enabled = true,
  });
  final TripPerson person;
  final String tripId;

  /// False once the trip is completed/cancelled — reached via a
  /// notification or Activities tap on an old trip shouldn't leave a live
  /// "call/message" affordance for someone the rider/driver has no ongoing
  /// reason to contact anymore.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Avatar(
          name: person.name,
          photoUrl: person is TripDriverPerson
              ? (person as TripDriverPerson).photoUrl
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                person.name?.isNotEmpty == true ? person.name! : '—',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (person.rating != null)
                Text(
                  '★ ${person.rating!.toStringAsFixed(1)} (${person.ratingCount})',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
        Material(
          color:
              enabled ? Colors.blue.shade600 : scheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          child: IconButton(
            icon: Icon(Icons.chat_rounded,
                color: enabled ? Colors.white : scheme.onSurfaceVariant),
            onPressed:
                enabled ? () => context.push(Routes.chat, extra: tripId) : null,
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color:
              enabled ? Colors.green.shade600 : scheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          child: IconButton(
            icon: Icon(Icons.call_rounded,
                color: enabled ? Colors.white : scheme.onSurfaceVariant),
            onPressed: enabled
                ? () => _showCallOptions(context, tripId, person.phone)
                : null,
            tooltip: AppL10n.of(context).callDriver,
          ),
        ),
      ],
    );
  }
}

/// A round, elevated map overlay button (back, etc.).
/// Lets the caller pick between the masked in-app call and their phone's own
/// dialer — skips straight to the in-app call when there's no real number to
/// offer yet (not shared until the trip is actively underway). Used from
/// `_CounterpartRow`, the sheet's one call button (there used to be a second,
/// separate one floating over the map — removed, this is the only one now).
Future<void> _showCallOptions(
    BuildContext context, String tripId, String? phone) async {
  if (phone == null) {
    context.push(Routes.call, extra: CallArgs(tripId: tripId, asCaller: true));
    return;
  }
  final l = AppL10n.of(context);
  final choice = await showModalBottomSheet<_CallChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.podcasts_rounded),
            title: Text(l.callInApp),
            subtitle: Text(l.callInAppBody),
            onTap: () => Navigator.pop(context, _CallChoice.inApp),
          ),
          ListTile(
            leading: const Icon(Icons.call_rounded),
            title: Text(l.callDirect),
            subtitle: Text(l.callDirectBody),
            onTap: () => Navigator.pop(context, _CallChoice.direct),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  switch (choice) {
    case _CallChoice.inApp:
      context.push(Routes.call,
          extra: CallArgs(tripId: tripId, asCaller: true));
    case _CallChoice.direct:
      final uri = Uri(scheme: 'tel', path: phone);
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {/* no dialer resolvable — nothing more we can do */}
  }
}

enum _CallChoice { inApp, direct }
