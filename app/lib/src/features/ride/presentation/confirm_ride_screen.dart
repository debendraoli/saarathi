import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../application/ride_controller.dart';
import '../data/ride_repository.dart';
import '../domain/models.dart';
import 'widgets/map_view.dart';

class ConfirmRideScreen extends ConsumerStatefulWidget {
  const ConfirmRideScreen({super.key, required this.draft});

  final RideDraft draft;

  @override
  ConsumerState<ConfirmRideScreen> createState() => _ConfirmRideScreenState();
}

class _ConfirmRideScreenState extends ConsumerState<ConfirmRideScreen> {
  String _payment = 'cash';
  bool _booking = false;

  Future<void> _book() async {
    setState(() => _booking = true);
    try {
      final draft = widget.draft.copyWith(paymentMethod: _payment);
      final trip = await ref.read(rideRepositoryProvider).book(draft);
      if (mounted) context.go('${Routes.trip}/${trip.id}');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorGeneric)),
        );
      }
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final estimate = ref.watch(fareEstimateProvider(widget.draft));
    final route = ref.watch(routeGeometryProvider(
      RouteQuery(widget.draft.path, widget.draft.vehicleClass.wire),
    ));

    return Scaffold(
      appBar: AppBar(title: Text(l.confirmRide)),
      body: Column(
        children: [
          Expanded(
            child: MapView(
              center: widget.draft.pickup.point,
              route: route.valueOrNull ?? widget.draft.path,
              pins: [
                MapPin(
                  widget.draft.pickup.point,
                  Icons.trip_origin,
                  Theme.of(context).colorScheme.primary,
                ),
                for (final s in widget.draft.stops)
                  MapPin(
                    s.point,
                    Icons.adjust_rounded,
                    Theme.of(context).colorScheme.tertiary,
                  ),
                MapPin(
                  widget.draft.destination.point,
                  Icons.location_on_rounded,
                  Theme.of(context).colorScheme.secondary,
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: estimate.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: LoadingView(),
                ),
                error: (_, __) => ErrorRetry(
                  message: l.errorNetwork,
                  onRetry: () =>
                      ref.invalidate(fareEstimateProvider(widget.draft)),
                ),
                data: (fare) => _FareCard(
                  fare: fare,
                  payment: _payment,
                  onPayment: (p) => setState(() => _payment = p),
                  booking: _booking,
                  onBook: _book,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FareCard extends StatelessWidget {
  const _FareCard({
    required this.fare,
    required this.payment,
    required this.onPayment,
    required this.booking,
    required this.onBook,
  });

  final FareEstimate fare;
  final String payment;
  final ValueChanged<String> onPayment;
  final bool booking;
  final VoidCallback onBook;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final surge = fare.surgeMultiplier > 1.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l.distanceDuration(
                  fare.distanceKm.toStringAsFixed(1), fare.durationMins),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            if (surge)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('×${fare.surgeMultiplier.toStringAsFixed(2)}'),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l.total, style: Theme.of(context).textTheme.titleMedium),
            Text(
              '${fare.currency} ${fare.finalFare.toStringAsFixed(0)}',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(
              value: 'cash',
              icon: const Icon(Icons.payments_rounded),
              label: Text(l.paymentCash),
            ),
            ButtonSegment(
              value: 'wallet',
              icon: const Icon(Icons.account_balance_wallet_rounded),
              label: Text(l.paymentWallet),
            ),
          ],
          selected: {payment},
          onSelectionChanged: (s) => onPayment(s.first),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: booking ? null : onBook,
          child: booking
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              : Text(l.confirmRide),
        ),
      ],
    );
  }
}
