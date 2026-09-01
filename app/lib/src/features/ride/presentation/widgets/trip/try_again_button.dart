import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../../../core/router/app_router.dart';
import '../../../../../shared/haptics.dart';
import '../../../application/ride_controller.dart';
import '../../../data/ride_repository.dart';
import '../../../domain/models.dart';

/// Re-requests a no-driver-cancelled trip with the same pickup/destination,
/// starting dispatch at a wider radius than whatever was just tried — so a
/// retry isn't just repeating the exact same failed search.
class TryAgainButton extends ConsumerStatefulWidget {
  const TryAgainButton({super.key, required this.trip});
  final Trip trip;

  @override
  ConsumerState<TryAgainButton> createState() => _TryAgainButtonState();
}

class _TryAgainButtonState extends ConsumerState<TryAgainButton> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    Haptics.tap();
    try {
      // No default radius is exposed by the API, so this mirrors the
      // service's own default (`Config::dispatch_radius_km`, 2km) as the
      // baseline to double from on a trip's first retry.
      final nextRadius = (widget.trip.searchRadiusKm ?? 2.0) * 2;
      final draft = RideDraft(
        pickup: Place(point: widget.trip.origin),
        destination: Place(point: widget.trip.dest),
        vehicleClass: VehicleClass.values.firstWhere(
          (v) => v.wire == widget.trip.vehicleClass,
          orElse: () => VehicleClass.twoWheeler,
        ),
        paymentMethod: widget.trip.paymentMethod,
        radiusKm: nextRadius,
        // Bid mode throughout, same as the normal booking flow — so if this
        // retry also finds nothing, the rider can raise the price on it too
        // rather than being stuck with another silent instant-mode search.
        pricingMode: 'bid',
        askFare: widget.trip.finalFare,
      );
      final newTrip = await ref.read(rideRepositoryProvider).book(draft);
      ref.invalidate(myTripsProvider);
      if (mounted) context.go('${Routes.trip}/${newTrip.id}');
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: _busy ? null : _retry,
      icon: _busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            )
          : const Icon(Icons.refresh_rounded),
      label: Text(AppL10n.of(context).tryAgainWiderSearch),
    );
  }
}
