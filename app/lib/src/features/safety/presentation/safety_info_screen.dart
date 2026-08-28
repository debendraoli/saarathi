import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../data/safety_repository.dart';
import '../domain/models.dart';

/// Safety hub: how the in-trip SOS button works, a few ride-safety tips, the
/// rider's own ride index, and an entry into trusted contacts. Static
/// content except the ride-index card, which is real data.
class SafetyInfoScreen extends ConsumerWidget {
  const SafetyInfoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final index = ref.watch(rideIndexProvider).value;

    return Scaffold(
      appBar: AppBar(title: Text(l.safetyTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          if (index != null) ...[
            _RideIndexCard(index: index),
            const SizedBox(height: 20),
          ],
          Card(
            child: ListTile(
              leading: Icon(Icons.contacts_rounded, color: scheme.primary),
              title: Text(l.trustedContactsTitle),
              subtitle: Text(l.trustedContactsBody, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(Routes.trustedContacts),
            ),
          ),
          const SizedBox(height: 20),
          Text(l.safetySosSectionTitle,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.emergency_rounded, color: scheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.safetySosSectionBody,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(l.safetyTipsSectionTitle,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (final tip in [l.safetyTip1, l.safetyTip2, l.safetyTip3])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tip)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RideIndexCard extends StatelessWidget {
  const _RideIndexCard({required this.index});
  final RideIndex index;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (color, title, body) = switch (index.level) {
      RideIndexLevel.green => (Colors.green.shade600, l.rideIndexGreenTitle, l.rideIndexGreenBody),
      RideIndexLevel.yellow => (Colors.amber.shade700, l.rideIndexYellowTitle, l.rideIndexYellowBody),
      RideIndexLevel.red => (scheme.error, l.rideIndexRedTitle, l.rideIndexRedBody),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.rideIndexTitle,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Container(height: 10, color: Colors.green.shade600),
                  ),
                  Expanded(
                    flex: 2,
                    child: Container(height: 10, color: Colors.amber.shade700),
                  ),
                  Expanded(
                    flex: 2,
                    child: Container(height: 10, color: scheme.error),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: switch (index.level) {
                RideIndexLevel.green => Alignment.centerLeft,
                RideIndexLevel.yellow => Alignment.center,
                RideIndexLevel.red => Alignment.centerRight,
              },
              child: Icon(Icons.arrow_drop_up_rounded, color: color, size: 28),
            ),
            const SizedBox(height: 8),
            Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 4),
            Text(body, style: Theme.of(context).textTheme.bodySmall),
            if (index.totalTrips > 0) ...[
              const SizedBox(height: 8),
              Text(
                l.rideIndexTripsSummary(index.cancelledByYou, index.totalTrips),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
