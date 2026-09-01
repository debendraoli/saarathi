import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../../core/location.dart';
import '../../../../../shared/haptics.dart';
import '../../../../safety/presentation/qr_scan_screen.dart';
import '../../../data/ride_repository.dart';
import '../../../domain/models.dart';

/// Single entry point into the Safety sheet — consolidates what used to be
/// two floating buttons (SOS, share trip) plus a third buried in the comms
/// bar (QR-scan driver verification).
class SafetyEntry extends StatelessWidget {
  const SafetyEntry({super.key, required this.trip, required this.isRider});
  final Trip trip;
  final bool isRider;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: () => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _SafetySheet(trip: trip, isRider: isRider),
      ),
      icon: Icon(Icons.shield_rounded, color: scheme.primary),
      label: Text(l.safety),
    );
  }
}

class _SafetySheet extends ConsumerStatefulWidget {
  const _SafetySheet({required this.trip, required this.isRider});
  final Trip trip;
  final bool isRider;

  @override
  ConsumerState<_SafetySheet> createState() => _SafetySheetState();
}

class _SafetySheetState extends ConsumerState<_SafetySheet> {
  // Local only — a pre-trip reminder checklist, not a record kept anywhere.
  final _checked = <int>{};

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final media = MediaQuery.of(context);
    final items = [
      l.safetyCheckVerifyDriver,
      l.safetyCheckShareTrip,
      l.safetyCheckBackSeat,
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 8, 20, 20 + media.viewInsets.bottom + media.padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.safety,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text(l.sos),
                        content: Text(l.sosConfirm),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(l.actionCancel),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(l.sos),
                          ),
                        ],
                      ),
                    );
                    if (ok == true && context.mounted) {
                      await _sendSos(context);
                    }
                  },
                  icon: const Icon(Icons.emergency_share_rounded),
                  label: Text(l.sos),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        Theme.of(context).colorScheme.errorContainer,
                    foregroundColor:
                        Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    final link = 'saarathi://trip/${widget.trip.id}';
                    SharePlus.instance.share(
                      ShareParams(
                        text: '${l.shareTripMessage}\n$link',
                        subject: l.shareTrip,
                      ),
                    );
                  },
                  icon: const Icon(Icons.ios_share_rounded),
                  label: Text(l.shareTrip),
                ),
              ),
            ],
          ),
          if (widget.isRider) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final code = await scanQr(context);
                if (code != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Verified: $code')),
                  );
                }
              },
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(l.scanVehicleQr),
            ),
          ],
          const SizedBox(height: 20),
          Text(l.safetyChecklistTitle,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          for (var i = 0; i < items.length; i++)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _checked.contains(i),
              title: Text(items[i]),
              onChanged: (v) => setState(() {
                if (v ?? false) {
                  _checked.add(i);
                } else {
                  _checked.remove(i);
                }
              }),
            ),
        ],
      ),
    );
  }

  Future<void> _sendSos(BuildContext context) async {
    Haptics.warning();
    final l = AppL10n.of(context);
    final repo = ref.read(rideRepositoryProvider);
    try {
      final here = await currentLatLng();
      await repo.sos(widget.trip.id, lat: here.latitude, lng: here.longitude);
    } catch (_) {/* best effort */}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          content: Text(l.sosSent),
        ),
      );
    }
  }
}
