import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../../../core/router/app_router.dart';
import '../../../../../shared/haptics.dart';
import '../../../../auth/application/auth_controller.dart';
import '../../../application/ride_controller.dart';
import '../../../domain/models.dart';
import '../rating_sheet.dart' show TripSummary;
import 'counterpart_row.dart';
import 'driver_expanded_detail.dart';
import 'driver_next_swipe.dart';
import 'eta_fare_row.dart';
import 'route_summary.dart';
import 'safety_sheet.dart';
import 'share_location_toggle.dart';
import 'trip_widgets_shared.dart';
import 'try_again_button.dart';
import 'vehicle_class_chip.dart';

/// The explicit "Cancel ride" button's flow — unlike [_leaveTrip] (back
/// arrow/gesture, which cancels silently so leaving stays a quick, low-
/// friction escape hatch), a deliberate cancel asks why first, **but only
/// once a driver has actually committed to the trip** (`accepted`/
/// `arriving`) — that's the only time a reason is meaningful feedback to
/// someone. While still [searching] (no driver assigned, or a bid-mode
/// auction with nobody won yet), cancelling has no one to explain it to, so
/// it goes through immediately, same as the back-gesture escape hatch.
Future<void> showCancelReasonSheet(
  BuildContext context,
  WidgetRef ref,
  String tripId,
  bool isDriver, {
  bool searching = false,
}) async {
  String? reason;
  if (searching) {
    Haptics.warning();
  } else {
    final l = AppL10n.of(context);
    final reasons = isDriver
        ? [
            l.driverCancelRiderRequested,
            l.driverCancelRiderUnresponsive,
            l.driverCancelWaitedTooLong,
            l.driverCancelWrongLocation,
            l.driverCancelVehicleIssue,
            l.cancelReasonOther,
          ]
        : [
            l.riderCancelDriverTooLong,
            l.riderCancelDriverNoShow,
            l.riderCancelWrongPickup,
            l.riderCancelPlansChanged,
            l.riderCancelFoundAnotherRide,
            l.cancelReasonOther,
          ];
    reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l.cancelReasonTitle,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final r in reasons)
              ListTile(
                title: Text(r),
                onTap: () => Navigator.pop(context, r),
              ),
          ],
        ),
      ),
    );
    if (reason == null || !context.mounted) return;
    Haptics.warning();
  }
  // Optimistic + retried in the background (see TripStatusUpdater) — this
  // stays a quick, non-blocking escape hatch regardless of how long the
  // actual request takes or whether it's currently offline.
  ref
      .read(tripStatusUpdaterProvider(tripId))
      .update('cancelled', reason: reason);
  ref.invalidate(myTripsProvider);
  if (!context.mounted) return;
  // A driver who cancels goes back to Home to pick up the next offer; a
  // rider goes back to the booking sheet to re-request.
  context.go(isDriver ? Routes.home : Routes.whereTo);
}

class StatusSheet extends ConsumerWidget {
  const StatusSheet(
      {super.key,
      required this.trip,
      this.driverLoc,
      required this.sheetController});
  final Trip trip;
  final LatLng? driverLoc;
  final DraggableScrollableController sheetController;

  /// Short status line only — the route (pickup/destination), live ETA, and
  /// fare each get their own dedicated row now instead of being crammed into
  /// this text.
  (IconData, String, String) _display(AppL10n l) {
    switch (trip.status) {
      case TripStatus.searching:
      case TripStatus.requested:
        return (Icons.search_rounded, l.findingDriver, l.findingDriverBody);
      case TripStatus.accepted:
      case TripStatus.arriving:
        return (
          Icons.directions_car_rounded,
          l.driverAssigned,
          l.statusArriving
        );
      case TripStatus.inProgress:
        return (Icons.navigation_rounded, l.statusOnTrip, '');
      case TripStatus.completed:
        return (Icons.check_circle_rounded, l.statusCompleted, '');
      case TripStatus.noDriver:
        return (Icons.search_off_rounded, l.noDriverFound, l.noDriverFoundBody);
      case TripStatus.cancelled:
        return trip.noDriverFound
            ? (Icons.search_off_rounded, l.noDriverFound, l.noDriverFoundBody)
            : (Icons.cancel_rounded, l.tripCancelled, '');
      default:
        return (Icons.info_outline_rounded, l.statusArriving, '');
    }
  }

  /// The driver's next forward transition + its button label, or null.
  (String, String)? _driverNext(AppL10n l) {
    switch (trip.status) {
      case TripStatus.accepted:
        return ('arriving', l.driverArrived);
      case TripStatus.arriving:
        return ('in_progress', l.startTrip);
      case TripStatus.inProgress:
        return ('completed', l.completeTrip);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final destLabelAsync = ref.watch(tripDestLabelProvider(trip.id));
    final originLabelAsync = ref.watch(tripOriginLabelProvider(trip.id));
    final destLabel = destLabelAsync.value;
    final originLabel = originLabelAsync.value;
    final (icon, title, body) = _display(l);
    final searching = trip.status == TripStatus.searching ||
        trip.status == TripStatus.requested;
    final done = trip.status == TripStatus.completed ||
        trip.status == TripStatus.cancelled ||
        trip.status == TripStatus.noDriver;
    final myId = ref.watch(authControllerProvider).user?.id;
    final iAmDriver = myId != null && myId == trip.driverId;
    final driverNext = iAmDriver ? _driverNext(l) : null;

    final participants = ref.watch(tripParticipantsProvider(trip.id));
    // A delivery trip's `origin` is the merchant's own location, not a
    // rider's pickup point — while the courier's still heading there
    // (`accepted`/`arriving`), the sheet should show who they're actually
    // about to interact with (the merchant), not the eventual delivery
    // recipient. Once `inProgress` (order in hand, heading to `dest`), it's
    // the recipient that matters, same as it always has been.
    final onPickupLeg = trip.status == TripStatus.accepted ||
        trip.status == TripStatus.arriving;
    final merchant = participants.value?.merchant;
    final TripPerson? counterpart = iAmDriver
        ? (trip.tripType == 'delivery' && onPickupLeg && merchant != null
            ? merchant.asTripPerson()
            : participants.value?.rider)
        : participants.value?.driver;
    final driverDetail = !iAmDriver ? participants.value?.driver : null;

    return DraggableScrollableSheet(
      controller: sheetController,
      initialChildSize: 0.32,
      minChildSize: 0.32,
      maxChildSize: 0.85,
      snap: true,
      snapSizes: const [0.32, 0.85],
      builder: (context, scrollController) {
        return Material(
          color: scheme.surface,
          elevation: 8,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.fromLTRB(
                18, 10, 18, 18 + MediaQuery.of(context).padding.bottom),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(icon, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (body.isNotEmpty)
                          Text(
                            body,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  if (searching)
                    const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                ],
              ),
              // The requested vehicle class — shown until the driver's own
              // vehicle detail (make/plate) takes over that job; without
              // this, a rider waiting for a match had no way to confirm
              // what they'd actually booked.
              if (!iAmDriver &&
                  driverDetail == null &&
                  trip.vehicleClass != null) ...[
                const SizedBox(height: 10),
                VehicleClassChip(vehicleClass: trip.vehicleClass!),
              ],
              if (trip.status != TripStatus.cancelled) ...[
                const SizedBox(height: 16),
                RouteSummary(pickup: originLabelAsync, dest: destLabelAsync),
                const SizedBox(height: 10),
                EtaFareRow(trip: trip, driverLoc: driverLoc),
              ],
              // Rider-only, and only while pickup hasn't happened yet — once
              // they're in the vehicle the driver already knows where they
              // are. See RiderLocationPublisher for what toggling this on
              // actually does.
              if (!iAmDriver &&
                  trip.status != TripStatus.inProgress &&
                  !done) ...[
                const SizedBox(height: 10),
                ShareLocationToggle(tripId: trip.id),
              ],
              if (counterpart != null) ...[
                const SizedBox(height: 14),
                CounterpartRow(
                  person: counterpart,
                  tripId: trip.id,
                  enabled: !done,
                ),
              ],
              if (trip.isActive) ...[
                const SizedBox(height: 14),
                SafetyEntry(trip: trip, isRider: !iAmDriver),
              ],
              if (driverNext != null) ...[
                const SizedBox(height: 16),
                DriverNextSwipe(tripId: trip.id, next: driverNext),
              ],
              if (searching ||
                  trip.status == TripStatus.accepted ||
                  trip.status == TripStatus.arriving) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => showCancelReasonSheet(
                      context, ref, trip.id, iAmDriver,
                      searching: searching),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side:
                        BorderSide(color: Theme.of(context).colorScheme.error),
                  ),
                  child: Text(l.cancelRide),
                ),
              ],
              if (done) ...[
                const SizedBox(height: 12),
                if (trip.status == TripStatus.completed)
                  FilledButton.icon(
                    onPressed: () => _rate(
                      context,
                      ref,
                      trip,
                      iAmDriver,
                      TripSummary(
                        pickupLabel: originLabel,
                        destLabel: destLabel,
                        fare: trip.finalFare,
                      ),
                    ),
                    icon: const Icon(Icons.star_rounded),
                    label: Text(
                        trip.rated ? l.editRatingAction : l.rateTripAction),
                  )
                else if (trip.noDriverFound)
                  TryAgainButton(trip: trip)
                else
                  FilledButton(
                    onPressed: () {
                      ref.invalidate(myTripsProvider);
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(Routes.home);
                      }
                    },
                    child: Text(l.actionDone),
                  ),
              ],
              if (driverDetail != null) ...[
                const Divider(height: 32),
                DriverExpandedDetail(driver: driverDetail, trip: trip),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _rate(BuildContext context, WidgetRef ref, Trip trip,
      bool iAmDriver, TripSummary summary) async {
    await autoRateTrip(
        context, ref, trip, ratingContextFor(trip, iAmDriver), summary);
    if (!context.mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
  }
}
