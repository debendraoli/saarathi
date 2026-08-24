import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/location.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/image_url.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/swipe_to_confirm.dart';
import '../../auth/application/auth_controller.dart';
import '../../comms/application/call_controller.dart';
import '../../comms/presentation/call_screen.dart';
import '../../safety/presentation/qr_scan_screen.dart';
import '../application/ride_controller.dart';
import '../application/trip_ws.dart';
import '../data/ride_repository.dart';
import '../domain/models.dart';
import '../domain/rating_tags.dart';
import 'widgets/bidding_sheet.dart';
import 'widgets/map_view.dart';
import 'widgets/rating_sheet.dart';
import 'widgets/search_radar.dart';

/// One screen for the whole live ride: searching → driver on the way → on trip →
/// completed. Status comes from polling; the driver pin from the trip WS.
class TripScreen extends ConsumerWidget {
  const TripScreen({super.key, required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final tripAsync = ref.watch(tripStreamProvider(tripId));
    final stale = ref.watch(tripStaleProvider(tripId));
    final driverPos = ref.watch(tripDriverPositionProvider(tripId)).valueOrNull;
    final driverLoc = driverPos?.point;

    // This screen is reached via context.go (replacing the stack, so a
    // stale confirm/checkout form can't be re-submitted from history), which
    // leaves nothing for the system back button/gesture to pop — without
    // this it exits the app instead of returning to Saarathi's home.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveTrip(context, ref, tripId);
      },
      child: Scaffold(
        body: Column(
          children: [
            if (stale) const StaleBanner(),
            Expanded(
              child: tripAsync.when(
                loading: () => const LoadingView(),
                error: (_, __) => ErrorRetry(
                  message: l.errorNetwork,
                  onRetry: () => retryTripPoll(ref, tripId),
                ),
                data: (trip) {
                  final myId = ref.watch(authControllerProvider).user?.id;
                  final iAmDriver = myId != null && myId == trip.driverId;
                  // While the driver's en route (either leg), the polyline
                  // should be the live remaining path from their current
                  // position, not the static original pickup→destination
                  // line — same target-switching `EtaFareRow` already does
                  // for the ETA text, just applied to the route query too.
                  final liveRouting = driverLoc != null && trip.isActive;
                  final routeTarget = trip.status == TripStatus.inProgress
                      ? trip.dest
                      : trip.origin;
                  final route = ref.watch(routeGeometryProvider(
                    RouteQuery(
                      liveRouting
                          ? [driverLoc, routeTarget]
                          : [trip.origin, trip.dest],
                      trip.vehicleClass ?? 'two_wheeler',
                    ),
                  ));
                  final searching = trip.status == TripStatus.searching ||
                      trip.status == TripStatus.requested;
                  final fixedPins = [
                    MapPin(
                      trip.origin,
                      Icons.trip_origin,
                      Theme.of(context).colorScheme.primary,
                    ),
                    MapPin(
                      trip.dest,
                      Icons.location_on_rounded,
                      Theme.of(context).colorScheme.secondary,
                    ),
                    if (driverLoc != null)
                      MapPin(
                        driverLoc,
                        Icons.navigation_rounded,
                        Theme.of(context).colorScheme.tertiary,
                        rotate: true,
                      ),
                  ];
                  // Navigation-mode camera (zoom in, follow, heading-up
                  // rotate) for either leg — driving to pickup or to the
                  // destination — but not while still searching/unassigned.
                  final navTarget = trip.isActive ? driverPos : null;
                  return Stack(
                    children: [
                      searching
                          ? SearchRadar(
                              origin: trip.origin,
                              builder: (context, driverPins, circles) =>
                                  MapView(
                                center: trip.origin,
                                route: route.valueOrNull ??
                                    [trip.origin, trip.dest],
                                circles: circles,
                                showLocateButton: true,
                                locateButtonBottomOffset:
                                    MediaQuery.of(context).size.height * 0.44,
                                pins: [
                                  ...fixedPins,
                                  for (final p in driverPins)
                                    MapPin(
                                      p,
                                      Icons.two_wheeler_rounded,
                                      Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                ],
                              ),
                            )
                          : MapView(
                              center: driverLoc ?? trip.origin,
                              route:
                                  route.valueOrNull ?? [trip.origin, trip.dest],
                              pins: fixedPins,
                              showLocateButton: true,
                              locateButtonBottomOffset:
                                  MediaQuery.of(context).size.height * 0.44,
                              navigationTarget: navTarget,
                            ),
                      // Invisible: routes incoming calls to the call screen.
                      _CallWatcher(tripId: tripId),
                      // Invisible: the driver streams position during an active trip.
                      if (iAmDriver && trip.isActive)
                        _DriverLocationPublisher(tripId: tripId),
                      SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _MapCircleButton(
                              icon: Icons.arrow_back_rounded,
                              onTap: () => _leaveTrip(context, ref, tripId),
                            ),
                          ),
                        ),
                      ),
                      trip.isBidding && trip.status == TripStatus.requested
                          ? BiddingSheet(trip: trip)
                          : _StatusSheet(trip: trip, driverLoc: driverLoc),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Leaves the trip screen (back arrow, system back gesture, or the explicit
/// "Cancel ride" button) — while the trip is still searching/unaccepted this
/// also cancels it server-side first, so navigating away doesn't strand a
/// live search running invisibly in the background; once a driver is
/// assigned, back just navigates (the active trip still shows on Home).
Future<void> _leaveTrip(
    BuildContext context, WidgetRef ref, String tripId) async {
  final trip = ref.read(tripStreamProvider(tripId)).valueOrNull;
  if (trip != null &&
      (trip.status == TripStatus.searching ||
          trip.status == TripStatus.requested)) {
    Haptics.warning();
    try {
      await ref.read(rideRepositoryProvider).cancel(tripId);
    } catch (_) {
      // Best-effort — still navigate away; a trip that failed to cancel
      // here just shows as active on Home, same as any other network blip.
    }
    // The home screen's search-bar lock reads this trip list — without
    // invalidating it, a just-cancelled trip still looks "active" and the
    // lock never lifts.
    ref.invalidate(myTripsProvider);
  }
  if (context.mounted) context.go(Routes.home);
}

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
  try {
    await ref.read(rideRepositoryProvider).cancel(tripId, reason: reason);
  } catch (_) {
    // Best-effort — still navigate away; a trip that failed to cancel here
    // just shows as active on Home, same as any other network blip.
  }
  ref.invalidate(myTripsProvider);
  if (context.mounted) context.go(Routes.home);
}

class _StatusSheet extends ConsumerWidget {
  const _StatusSheet({required this.trip, this.driverLoc});
  final Trip trip;
  final LatLng? driverLoc;

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
    final destLabel = destLabelAsync.valueOrNull;
    final originLabel = originLabelAsync.valueOrNull;
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
    final TripPerson? counterpart = iAmDriver
        ? participants.valueOrNull?.rider
        : participants.valueOrNull?.driver;
    final driverDetail = !iAmDriver ? participants.valueOrNull?.driver : null;

    return DraggableScrollableSheet(
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
              if (trip.status != TripStatus.cancelled) ...[
                const SizedBox(height: 16),
                RouteSummary(pickup: originLabelAsync, dest: destLabelAsync),
                const SizedBox(height: 10),
                EtaFareRow(trip: trip, driverLoc: driverLoc),
              ],
              if (counterpart != null) ...[
                const SizedBox(height: 14),
                _CounterpartRow(person: counterpart, tripId: trip.id),
              ],
              if (trip.isActive) ...[
                const SizedBox(height: 14),
                _SafetyEntry(trip: trip, isRider: !iAmDriver),
              ],
              if (driverNext != null) ...[
                const SizedBox(height: 16),
                _DriverNextSwipe(tripId: trip.id, next: driverNext),
              ],
              if (searching ||
                  trip.status == TripStatus.accepted ||
                  trip.status == TripStatus.arriving) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => showCancelReasonSheet(
                      context, ref, trip.id, iAmDriver,
                      searching: searching),
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
                  _TryAgainButton(trip: trip)
                else
                  FilledButton(
                    onPressed: () {
                      ref.invalidate(myTripsProvider);
                      context.go(Routes.home);
                    },
                    child: Text(l.actionDone),
                  ),
              ],
              if (driverDetail != null) ...[
                const Divider(height: 32),
                _DriverExpandedDetail(driver: driverDetail, trip: trip),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _rate(BuildContext context, WidgetRef ref, Trip trip,
      bool iAmDriver, TripSummary summary) async {
    final ratingContext = iAmDriver
        ? RatingContext.driverRatesRider
        : trip.tripType == 'delivery'
            ? RatingContext.senderRatesCourier
            : RatingContext.riderRatesDriver;
    final result = await showRatingSheet(
      context,
      ratingContext: ratingContext,
      summary: summary,
    );
    if (result == null) return;
    try {
      await ref
          .read(rideRepositoryProvider)
          .rate(trip.id, result.stars, tags: result.tags);
    } catch (_) {/* non-blocking */}
    ref.invalidate(myTripsProvider);
    if (!context.mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Routes.home);
    }
  }
}

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
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RoutePoint(
          icon: Icons.trip_origin,
          color: scheme.primary,
          value: pickup,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 7),
          child: SizedBox(
            height: 14,
            child: VerticalDivider(width: 14, color: scheme.outlineVariant),
          ),
        ),
        _RoutePoint(
          icon: Icons.location_on_rounded,
          color: scheme.secondary,
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
    // (not `.valueOrNull`) is deliberate: it also surfaces the last-known
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
                  value.valueOrNull ?? AppL10n.of(context).addressUnavailable,
                  style: theme.textTheme.bodyMedium,
                ),
        ),
      ],
    );
  }
}

/// Distance, live ETA (recomputed from the driver's current position as it
/// updates), and fare, in one compact row — visible across every active
/// status, not just once the trip is done. Distance/duration come straight
/// off the trip (computed once at booking, from the route), so they're
/// available even before a driver's been found.
class EtaFareRow extends ConsumerWidget {
  const EtaFareRow({
    super.key,
    required this.trip,
    required this.driverLoc,
    this.showFare = true,
  });
  final Trip trip;
  final LatLng? driverLoc;

  /// Bid-mode trips already show the rider's live ask in [FareStepper] right
  /// below this row — repeating the algorithmic estimate here too would put
  /// two unlabeled fare numbers on screen at once, so callers that already
  /// show their own fare can turn this one off.
  final bool showFare;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final routingToPickup = trip.status == TripStatus.accepted ||
        trip.status == TripStatus.arriving;
    final routingToDest = trip.status == TripStatus.inProgress;

    String? etaText;
    if ((routingToPickup || routingToDest) && driverLoc != null) {
      final target = routingToPickup ? trip.origin : trip.dest;
      final eta =
          ref.watch(tripEtaProvider(EtaQuery(driverLoc!, target))).valueOrNull;
      if (eta != null) {
        etaText = routingToPickup
            ? l.etaArriving(eta.durationMins)
            : l.etaToDestination(eta.durationMins);
      }
    } else if (trip.durationSecs != null &&
        (trip.status == TripStatus.searching ||
            trip.status == TripStatus.requested)) {
      etaText = l.etaToDestination((trip.durationSecs! / 60).ceil());
    }

    return Row(
      children: [
        if (trip.distanceKm > 0) ...[
          Icon(Icons.route_rounded,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('${trip.distanceKm.toStringAsFixed(1)} km',
              style: theme.textTheme.bodyMedium),
          const SizedBox(width: 14),
        ],
        if (etaText != null) ...[
          Icon(Icons.schedule_rounded,
              size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(etaText, style: theme.textTheme.bodyMedium),
        ],
        const Spacer(),
        if (showFare)
          Text(
            'NPR ${trip.finalFare.toStringAsFixed(2)}',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
      ],
    );
  }
}

/// Single entry point into the Safety sheet — consolidates what used to be
/// two floating buttons (SOS, share trip) plus a third buried in the comms
/// bar (QR-scan driver verification).
class _SafetyEntry extends StatelessWidget {
  const _SafetyEntry({required this.trip, required this.isRider});
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

/// Photo (driver) or initials avatar (rider — no photo concept exists).
/// The driver's forward trip-progression control (arrived → start → complete).
/// Owns its own busy/error handling — unlike a plain inline `SwipeToConfirm`,
/// a failed request here must not leave the thumb stuck showing "confirmed"
/// with no feedback, since it's real money/obligation on the line.
/// Re-requests a no-driver-cancelled trip with the same pickup/destination,
/// starting dispatch at a wider radius than whatever was just tried — so a
/// retry isn't just repeating the exact same failed search.
class _TryAgainButton extends ConsumerStatefulWidget {
  const _TryAgainButton({required this.trip});
  final Trip trip;

  @override
  ConsumerState<_TryAgainButton> createState() => _TryAgainButtonState();
}

class _TryAgainButtonState extends ConsumerState<_TryAgainButton> {
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

class _DriverNextSwipe extends ConsumerStatefulWidget {
  const _DriverNextSwipe({required this.tripId, required this.next});
  final String tripId;
  final (String, String) next;

  @override
  ConsumerState<_DriverNextSwipe> createState() => _DriverNextSwipeState();
}

class _DriverNextSwipeState extends ConsumerState<_DriverNextSwipe> {
  bool _busy = false;

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(rideRepositoryProvider)
          .updateStatus(widget.tripId, widget.next.$1);
      ref.invalidate(tripStreamProvider(widget.tripId));
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                e.isNetwork ? AppL10n.of(context).errorNetwork : e.message)));
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwipeToConfirm(
      label: widget.next.$2,
      busy: _busy,
      onConfirmed: _confirm,
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({this.name, this.photoUrl, this.radius = 22});
  final String? name;
  final String? photoUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = asImageUrl(photoUrl);
    if (url != null) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(url));
    }
    final initials = (name == null || name!.trim().isEmpty)
        ? '?'
        : name!
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((s) => s[0].toUpperCase())
            .join();
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.secondaryContainer,
      child: Text(
        initials,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Collapsed-state counterpart identity: avatar, name, rating, and a
/// Counterpart identity, plus the trip's one chat button and one call
/// button (previously there were two call buttons — a second, separate one
/// floating over the map — merged into just this one). The call button
/// opens the masked-in-app-vs-direct-dial picker; direct dial is unavailable
/// (button hidden) until `phone` is non-null (trip not yet active, or
/// already finished).
class _CounterpartRow extends StatelessWidget {
  const _CounterpartRow({required this.person, required this.tripId});
  final TripPerson person;
  final String tripId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        _Avatar(
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
          color: scheme.surfaceContainerHighest,
          shape: const CircleBorder(),
          child: IconButton(
            icon: const Icon(Icons.chat_rounded),
            onPressed: () => context.push(Routes.chat, extra: tripId),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: scheme.primaryContainer,
          shape: const CircleBorder(),
          child: IconButton(
            icon: Icon(Icons.call_rounded, color: scheme.onPrimaryContainer),
            onPressed: () => _showCallOptions(context, tripId, person.phone),
            tooltip: AppL10n.of(context).callDriver,
          ),
        ),
      ],
    );
  }
}

/// Revealed when the sheet is swiped up: bigger photo, fleet-partner name,
/// vehicle + plate, and the fare breakdown. Rider-only (the counterpart
/// being expanded is always the driver — a driver has no analogous "vehicle"
/// to show about their rider).
class _DriverExpandedDetail extends StatelessWidget {
  const _DriverExpandedDetail({required this.driver, required this.trip});
  final TripDriverPerson driver;
  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child:
              _Avatar(name: driver.name, photoUrl: driver.photoUrl, radius: 40),
        ),
        if (driver.partnerName != null) ...[
          const SizedBox(height: 10),
          Center(
            child: Text(
              driver.partnerName!,
              style: textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        const SizedBox(height: 18),
        if (driver.vehicleLabel.isNotEmpty || driver.plateNumber != null)
          _DetailRow(
            icon: Icons.two_wheeler_rounded,
            label: [
              if (driver.vehicleLabel.isNotEmpty) driver.vehicleLabel,
              if (driver.plateNumber != null && driver.plateNumber!.isNotEmpty)
                driver.plateNumber!,
            ].join(' · '),
          ),
        const SizedBox(height: 10),
        _DetailRow(
          icon: Icons.payments_rounded,
          label: 'NPR ${trip.finalFare.toStringAsFixed(0)}'
              '${trip.distanceKm > 0 ? ' · ${trip.distanceKm.toStringAsFixed(1)} km' : ''}',
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
      ],
    );
  }
}

/// A round, elevated map overlay button (back, etc.).
class _MapCircleButton extends StatelessWidget {
  const _MapCircleButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(icon: Icon(icon), onPressed: onTap),
    );
  }
}

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

/// Watches for an incoming WebRTC call and opens the call screen to answer.
class _CallWatcher extends ConsumerStatefulWidget {
  const _CallWatcher({required this.tripId});
  final String tripId;

  @override
  ConsumerState<_CallWatcher> createState() => _CallWatcherState();
}

class _CallWatcherState extends ConsumerState<_CallWatcher> {
  CallController? _controller;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(callControllerProvider(widget.tripId));
    _controller!.addListener(_check);
  }

  Future<void> _check() async {
    if (_open) return;
    if (_controller!.status == CallStatus.incoming) {
      _open = true;
      await context.push(
        Routes.call,
        extra: CallArgs(tripId: widget.tripId, asCaller: false),
      );
      _open = false;
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch to keep the call controller (and its signaling) alive.
    ref.watch(callControllerProvider(widget.tripId));
    return const SizedBox.shrink();
  }
}

/// While a driver is on an active trip, publish live position every few seconds.
class _DriverLocationPublisher extends ConsumerStatefulWidget {
  const _DriverLocationPublisher({required this.tripId});
  final String tripId;

  @override
  ConsumerState<_DriverLocationPublisher> createState() =>
      _DriverLocationPublisherState();
}

class _DriverLocationPublisherState
    extends ConsumerState<_DriverLocationPublisher> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ping();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _ping());
  }

  Future<void> _ping() async {
    try {
      // Not `currentLatLng()` here — it discards everything but lat/lng, and
      // the navigation camera (heading-up rotation) needs `heading`/`speed`
      // too. Same permission/service gating as `currentLatLng()`, just
      // keeping the full `Position`.
      if (!await ensureLocationPermission() ||
          !await Geolocator.isLocationServiceEnabled()) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await ref.read(rideRepositoryProvider).postLocation(
            widget.tripId,
            pos.latitude,
            pos.longitude,
            heading: pos.heading,
            speed: pos.speed,
          );
    } catch (_) {/* skip a beat */}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
