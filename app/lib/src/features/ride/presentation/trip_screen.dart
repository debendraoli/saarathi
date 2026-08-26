import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/location.dart';
import '../../../core/offline/connectivity.dart';
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
import 'navigation_screen.dart';
import 'widgets/bidding_sheet.dart';
import 'widgets/map_view.dart';
import 'widgets/rating_sheet.dart';
import 'widgets/search_radar.dart';

/// Fraction of screen height the bottom status/bidding sheet occupies at
/// rest (its `DraggableScrollableSheet.minChildSize`, see `_StatusSheet`) —
/// map controls that need to sit just above it (locate button, fullscreen
/// nav, back) share this so they dock right at the sheet's collapsed top
/// edge instead of floating with a large, arbitrary gap above it.
const _sheetClearance = 0.32;

/// The map-pin icon for a driver of the given vehicle class — same mapping
/// [_VehicleClassChip] uses for the trip-details chip, so the live driver
/// marker reads as "a two-wheeler/rickshaw/car", not a generic arrow.
IconData vehicleIconFor(String? vehicleClass) => switch (vehicleClass) {
      'three_wheeler' => Icons.electric_rickshaw_rounded,
      'four_wheeler' => Icons.directions_car_rounded,
      _ => Icons.two_wheeler_rounded,
    };

/// One screen for the whole live ride: searching → driver on the way → on trip →
/// completed. Status comes from polling; the driver pin from the trip WS.
class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({super.key, required this.tripId});

  final String tripId;

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  // `routeGeometryProvider` is keyed by a `RouteQuery` embedding the live
  // driver `LatLng` while `liveRouting` is on, so practically every ~5s GPS
  // ping is a fresh `.autoDispose.family` instance with nothing cached from
  // the last one — `route.valueOrNull` goes null for that loading window on
  // every ping. Without this, the fallback below silently swaps to the
  // static straight pickup→destination line each time, which reads as the
  // live route "disappearing" (see `NavigationScreen`'s identical fix, same
  // root cause). Stashing the last successfully-fetched geometry here means
  // the map keeps showing the last-known road route while a fresher one is
  // still in flight.
  List<LatLng>? _lastRouteGeometry;

  // Same churn concern as `NavigationScreen`'s identical field: re-querying
  // on literally every raw GPS ping means a fresh `.autoDispose.family`
  // provider instance every ~5s for as long as `liveRouting` is on — this
  // throttles the query point so the family key stays stable across most
  // pings instead.
  static const _routeRequeryMeters = 25.0;
  LatLng? _routeQueryPoint;

  LatLng _throttledRoutePoint(LatLng liveLoc) {
    final last = _routeQueryPoint;
    if (last == null ||
        const Distance().as(LengthUnit.Meter, last, liveLoc) >
            _routeRequeryMeters) {
      _routeQueryPoint = liveLoc;
    }
    return _routeQueryPoint!;
  }

  @override
  Widget build(BuildContext context) {
    final tripId = widget.tripId;
    final l = AppL10n.of(context);
    final tripAsync = ref.watch(effectiveTripProvider(tripId));
    final stale = ref.watch(tripStaleProvider(tripId));
    final online = ref.watch(connectivityProvider).valueOrNull ?? true;

    // A rider whose driver cancels on them (after having been accepted)
    // otherwise just sits on a "Trip cancelled" status line with no clear
    // next step — this notices the transition and takes them straight back
    // to the booking sheet instead of leaving them to notice and back out
    // manually. Scoped specifically to a driver-initiated cancellation
    // (`cancelledByRole`): the rider's *own* cancel already navigates
    // itself (see `_leaveTrip`/`showCancelReasonSheet`), and re-triggering
    // here too would just double-navigate.
    ref.listen(effectiveTripProvider(tripId), (prev, next) {
      final trip = next.valueOrNull;
      final prevTrip = prev?.valueOrNull;
      if (trip == null || prevTrip == null) return;
      final justCancelled = trip.status == TripStatus.cancelled &&
          prevTrip.status != TripStatus.cancelled;
      if (!justCancelled || trip.cancelledByRole != 'driver') return;
      // Deferred to the next frame, not just guarded with `if (!mounted)`
      // right here — `mounted` stays true through Flutter's `deactivate()`
      // (this screen can be mid-teardown, e.g. popped right as the trip's
      // own state updates, when this listener fires), and the specific
      // assertion `ref.read`/`context` trip below checks a *stricter*
      // "active" lifecycle state that deactivate() already exits. Confirmed
      // live: the `if (!mounted) return;` version still crashed at the
      // exact same line. Deferring past this frame's build gives Flutter
      // time to resolve deactivation to either fully disposed (caught by
      // `mounted` below, correctly this time) or reactivated (safe either
      // way).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final myId = ref.read(authControllerProvider).user?.id;
        final iAmRider = myId != null && myId == trip.riderId;
        if (!iAmRider) return;
        Haptics.warning();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.driverCancelledNotice)),
        );
        context.go(Routes.whereTo);
      });
    });

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
                  final iAmRider = myId != null && myId == trip.riderId;
                  // The driver's own device always prefers its own local GPS
                  // fix (see `localDriverPositionProvider`) over the one
                  // that's round-tripped through `POST location` → backend →
                  // this trip's WebSocket — that keeps the driver's own
                  // marker/camera moving even when offline or on a bad
                  // connection. A rider has no local GPS of the *driver* and
                  // always falls back to the WS-fed position.
                  final remoteDriverPos =
                      ref.watch(tripDriverPositionProvider(tripId)).valueOrNull;
                  final localDriverPos = ref.watch(localDriverPositionProvider);
                  final driverPos = iAmDriver
                      ? (localDriverPos ?? remoteDriverPos)
                      : remoteDriverPos;
                  final driverLoc = driverPos?.point;
                  // The driver's own screen only, pre-pickup: if the rider
                  // has opted in (`RiderLocationPublisher`, gated on their
                  // own `riderShareLocationProvider` toggle), route toward
                  // where they actually are right now instead of the pickup
                  // point they originally selected — useful when they're
                  // walking to a meeting point or the pin itself is
                  // imprecise. Once pickup happens the rider's in the
                  // vehicle, so this stops mattering.
                  final riderLivePos = iAmDriver &&
                          trip.status != TripStatus.inProgress &&
                          trip.status != TripStatus.completed
                      ? ref.watch(tripRiderPositionProvider(tripId)).valueOrNull
                      : null;
                  // While the driver's en route (either leg), the polyline
                  // should be the live remaining path from their current
                  // position, not the static original pickup→destination
                  // line — same target-switching `EtaFareRow` already does
                  // for the ETA text, just applied to the route query too.
                  final liveRouting = driverLoc != null && trip.isActive;
                  final routeTarget = trip.status == TripStatus.inProgress
                      ? trip.dest
                      : (riderLivePos?.point ?? trip.origin);
                  final freshRoute = ref
                      .watch(routeGeometryProvider(
                        RouteQuery(
                          liveRouting
                              ? [_throttledRoutePoint(driverLoc), routeTarget]
                              : [trip.origin, trip.dest],
                          trip.vehicleClass ?? 'two_wheeler',
                        ),
                      ))
                      .valueOrNull;
                  if (freshRoute != null) _lastRouteGeometry = freshRoute;
                  final routeGeometry =
                      _lastRouteGeometry ?? [trip.origin, trip.dest];
                  // Same ETA `EtaFareRow` already shows as sheet text —
                  // also floated right on the map next to the point it's
                  // about, previously visible only by having the sheet
                  // expanded (or knowing to look for it there at all).
                  final routingToPickup = trip.status == TripStatus.accepted ||
                      trip.status == TripStatus.arriving;
                  final etaMins =
                      (routingToPickup || trip.status == TripStatus.inProgress) &&
                              driverLoc != null
                          ? ref
                              .watch(
                                  tripEtaProvider(EtaQuery(driverLoc, routeTarget)))
                              .valueOrNull
                              ?.durationMins
                          : null;
                  final mapCallouts = <MapCallout>[
                    if (etaMins != null)
                      MapCallout(
                        point: routeTarget,
                        text: routingToPickup
                            ? l.etaArriving(etaMins)
                            : l.etaToDestination(etaMins),
                      ),
                  ];
                  final searching = trip.status == TripStatus.searching ||
                      trip.status == TripStatus.requested;
                  // The rider's own "you are here" arrow, shown only while
                  // there's no driver marker yet to orient by instead —
                  // superseded the instant one is assigned (`driverLoc`
                  // above already prefers the driver once available). Not
                  // for a driver (that's just their own live GPS dot, no
                  // separate marker needed) or a merchant (who only cares
                  // about the courier's heading, not their own).
                  final selfPos = iAmRider && driverLoc == null
                      ? ref.watch(localSelfPositionProvider)
                      : null;
                  final fixedPins = [
                    MapPin(
                      riderLivePos?.point ?? trip.origin,
                      Icons.emoji_people_rounded,
                      Theme.of(context).colorScheme.primary,
                      heading: riderLivePos?.heading,
                    ),
                    MapPin(
                      trip.dest,
                      Icons.sports_score_rounded,
                      Theme.of(context).colorScheme.secondary,
                    ),
                    if (driverLoc != null)
                      MapPin(
                        driverLoc,
                        vehicleIconFor(trip.vehicleClass),
                        Theme.of(context).colorScheme.tertiary,
                        heading: driverPos?.heading,
                        id: 'driver',
                      ),
                    if (selfPos != null)
                      MapPin(
                        selfPos.point,
                        Icons.navigation_rounded,
                        routeLineColor,
                        heading: selfPos.heading,
                        id: 'self',
                      ),
                  ];
                  return Stack(
                    children: [
                      searching
                          ? SearchRadar(
                              origin: trip.origin,
                              builder: (context, driverPins, circles) =>
                                  MapView(
                                center: trip.origin,
                                route: routeGeometry,
                                circles: circles,
                                showLocateButton: true,
                                locateButtonBottomOffset:
                                    MediaQuery.of(context).size.height *
                                        _sheetClearance,
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
                              route: routeGeometry,
                              pins: fixedPins,
                              callouts: mapCallouts,
                              showRecenterButton: true,
                              locateButtonBottomOffset:
                                  MediaQuery.of(context).size.height *
                                      _sheetClearance,
                              // Deliberately not `navigationTarget` — that
                              // drives its camera glide off every heading
                              // update, and the device compass fires many
                              // times a second even stationary. On this
                              // small in-trip map that churn was reliably
                              // producing a `_dependents.isEmpty` framework
                              // crash and a momentarily-flipped marker
                              // (confirmed live, reproduced while
                              // rotating/testing the phone) — a >3° throttle
                              // on the animation restart wasn't enough to
                              // fully rule it out. `autoFitPins` instead:
                              // its own change-detection only looks at pin
                              // *positions*, never heading, so compass noise
                              // can't trigger it at all — it only re-fits
                              // when the driver's point actually moves
                              // (~5s GPS ping cadence). The vehicle pin
                              // still turns in place via its own `heading`;
                              // only the *camera* auto-follow moved to the
                              // fullscreen NavigationScreen, the one place
                              // that dedicated heading-up nav experience
                              // actually belongs.
                              autoFitPins: true,
                            ),
                      // Invisible: routes incoming calls to the call screen.
                      _CallWatcher(tripId: tripId),
                      // Invisible: feeds the rider's own "you are here"
                      // arrow above until a driver is assigned.
                      if (iAmRider && driverLoc == null && trip.isActive)
                        const _SelfLocationWatcher(),
                      // Back (leave trip) always docks top-left, stacked
                      // above the offline banner when both are showing —
                      // previously positioned just above the status/bidding
                      // sheet's edge instead, which the sheet (painted after
                      // it, so on top) could cover entirely once dragged
                      // open past its collapsed size, or — after an attempt
                      // to track the sheet's live extent instead of a fixed
                      // offset — could vanish outright from an unrelated
                      // layout bug in that tracking code. Docking top
                      // instead of bottom sidesteps the whole class of
                      // "the draggable sheet might be covering this" bugs:
                      // the sheet only ever grows from the bottom, so
                      // nothing here can ever be under it.
                      SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                MapCircleButton(
                                  icon: Icons.arrow_back_rounded,
                                  onTap: () =>
                                      _leaveTrip(context, ref, tripId),
                                ),
                                if (!online) ...[
                                  const SizedBox(height: 8),
                                  const OfflineBanner(),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      // Own-position/heading only starts updating once the
                      // first GPS fix lands — genuinely variable timing
                      // (near-instant warm, several seconds cold). Without
                      // this, that wait looked identical to a broken
                      // compass; confirmed live as an intermittent,
                      // hard-to-reproduce "compass doesn't respond" report.
                      if ((iAmDriver && trip.isActive && driverLoc == null) ||
                          (iAmRider &&
                              trip.isActive &&
                              driverLoc == null &&
                              selfPos == null))
                        const SafeArea(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: LocatingIndicator(),
                            ),
                          ),
                        ),
                      // Invisible: the driver streams position during an active trip.
                      if (iAmDriver && trip.isActive)
                        _DriverLocationPublisher(tripId: tripId),
                      // Invisible: the rider streams their own position once
                      // they've opted in, until pickup (see riderLivePos
                      // above for why it stops mattering after that).
                      if (iAmRider &&
                          trip.isActive &&
                          trip.status != TripStatus.inProgress &&
                          ref.watch(riderShareLocationProvider(tripId)))
                        RiderLocationPublisher(tripId: tripId),
                      // External Google Maps hand-off and the in-app
                      // fullscreen nav button both dock top-right, stacked —
                      // same "never under the draggable sheet" reasoning as
                      // the back button above; previously the fullscreen
                      // button specifically was positioned just above the
                      // sheet's edge and could end up covered by it, or
                      // (after a fix attempt that tracked the sheet's live
                      // extent instead) disappear entirely from a layout bug
                      // in that tracking code.
                      if (iAmDriver && trip.isActive)
                        SafeArea(
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  MapCircleButton(
                                    icon: Icons.navigation_rounded,
                                    iconColor: const Color(0xFF4285F4),
                                    onTap: () =>
                                        _launchExternalNavigation(routeTarget),
                                  ),
                                  const SizedBox(height: 8),
                                  MapCircleButton(
                                    icon: Icons.fullscreen_rounded,
                                    tooltip: l.navFullscreen,
                                    onTap: () => context.push(
                                      '${Routes.tripNavigate}/$tripId/navigate',
                                      extra: NavigationScreenArgs(
                                        target: routeTarget,
                                        vehicleClass:
                                            trip.vehicleClass ?? 'two_wheeler',
                                      ),
                                    ),
                                  ),
                                ],
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

/// Opens the platform's Google Maps app for turn-by-turn to [target] — this
/// URL scheme launches the native app directly when installed, falling back
/// to Maps in a browser otherwise, so no platform-specific intent handling
/// is needed.
Future<void> _launchExternalNavigation(LatLng target) async {
  final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${target.latitude},${target.longitude}&travelmode=driving');
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {/* no maps app resolvable — nothing more we can do */}
}

/// Leaves the trip screen (back arrow, system back gesture, or the explicit
/// "Cancel ride" button) — while the trip is still searching/unaccepted this
/// also cancels it server-side first, so navigating away doesn't strand a
/// live search running invisibly in the background; once a driver is
/// assigned, back just navigates (the active trip still shows on Home).
Future<void> _leaveTrip(
    BuildContext context, WidgetRef ref, String tripId) async {
  final trip = ref.read(tripStreamProvider(tripId)).valueOrNull;
  final cancelling = trip != null &&
      (trip.status == TripStatus.searching ||
          trip.status == TripStatus.requested);
  if (cancelling) {
    Haptics.warning();
    // Optimistic + retried in the background (see TripStatusUpdater) — this
    // screen navigates away immediately below regardless of how long the
    // actual request takes or whether it's currently offline, rather than
    // blocking the back gesture on a network round-trip.
    ref.read(tripStatusUpdaterProvider(tripId)).update('cancelled');
    // The home screen's search-bar lock reads this trip list — without
    // invalidating it, a just-cancelled trip still looks "active" and the
    // lock never lifts.
    ref.invalidate(myTripsProvider);
  }
  if (!context.mounted) return;
  if (cancelling) {
    // A rider whose still-searching request just got cancelled goes back to
    // the booking sheet to re-request, not wherever this screen happened to
    // be pushed from — this status only ever occurs before a driver is
    // assigned, i.e. only for riders, and only for the live booking flow
    // (which reaches this screen via `context.go`, not a push).
    context.go(Routes.whereTo);
    return;
  }
  // This screen is reached two different ways: `context.go` from the live
  // booking flow (nothing to pop back to — go home), and `context.push`
  // from a trip in history (Activities, an order's "track courier", etc.),
  // where there's a real caller to return to instead of blowing past it to
  // Home.
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(Routes.home);
  }
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
              // The requested vehicle class — shown until the driver's own
              // vehicle detail (make/plate) takes over that job; without
              // this, a rider waiting for a match had no way to confirm
              // what they'd actually booked.
              if (!iAmDriver &&
                  driverDetail == null &&
                  trip.vehicleClass != null) ...[
                const SizedBox(height: 10),
                _VehicleClassChip(vehicleClass: trip.vehicleClass!),
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
                _ShareLocationToggle(tripId: trip.id),
              ],
              if (counterpart != null) ...[
                const SizedBox(height: 14),
                _CounterpartRow(
                  person: counterpart,
                  tripId: trip.id,
                  enabled: !done,
                ),
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
                  _TryAgainButton(trip: trip)
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

  /// Applies the status change optimistically and hands the actual `POST`
  /// off to [TripStatusUpdater], which keeps retrying independently of
  /// this widget's own lifetime — this swipe control is very likely to be
  /// unmounted the instant the optimistic status takes effect (advancing
  /// past `inProgress` means there's no more "next" swipe to show at all),
  /// so nothing here can afford to own the retry itself. The brief
  /// `busy: true → false` flip isn't gating on the network at all anymore —
  /// it purely exists to replay `SwipeToConfirm`'s own confirmed→ready reset
  /// (see its `didUpdateWidget`) across two real frames, so the thumb is
  /// clean and ready in case this exact widget somehow gets a *different*
  /// `next` transition to show before the trip poll catches up.
  Future<void> _confirm() async {
    try {
      ref.read(tripStatusUpdaterProvider(widget.tripId)).update(widget.next.$1);
      Haptics.success();
    } catch (_) {
      // Fall through regardless — the busy-cycle below is what resets
      // SwipeToConfirm's own `_confirmed` flag (see its didUpdateWidget).
      // Skipping it on an exception here would leave the thumb visually
      // locked in "confirmed" forever with no way to retry, confirmed live
      // as a stuck "I've arrived" swipe.
    }
    if (mounted) setState(() => _busy = true);
    await Future<void>.delayed(Duration.zero);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      // Previously stretched to the sheet's full width (minus its 18px
      // margins) — on a typical phone that's most of the screen, both
      // reading as visually oversized and requiring a swipe long enough
      // that it was easy to under-drag past the commit threshold and land
      // right back at the start, confirmed live as feeling "stuck".
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: SwipeToConfirm(
          label: widget.next.$2,
          busy: _busy,
          onConfirmed: _confirm,
          // Green — reads as "go/forward" opposite the cancel button's red,
          // instead of both actions sharing the same brand-amber look.
          color: Colors.green.shade600,
        ),
      ),
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
      return CircleAvatar(
          radius: radius, backgroundImage: CachedNetworkImageProvider(url));
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
/// Rider-only toggle: when on, [RiderLocationPublisher] starts posting their
/// live GPS so the driver sees it instead of the static pickup pin (see that
/// class's doc comment). Purely local UI state (`riderShareLocationProvider`)
/// — nothing is persisted, so this always starts off for a fresh trip.
class _ShareLocationToggle extends ConsumerWidget {
  const _ShareLocationToggle({required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final sharing = ref.watch(riderShareLocationProvider(tripId));
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => ref
          .read(riderShareLocationProvider(tripId).notifier)
          .update((v) => !v),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              sharing ? Icons.share_location_rounded : Icons.location_off_rounded,
              color: sharing ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.shareLiveLocation,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    l.shareLiveLocationBody,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Switch(
              value: sharing,
              onChanged: (v) => ref
                  .read(riderShareLocationProvider(tripId).notifier)
                  .state = v,
            ),
          ],
        ),
      ),
    );
  }
}

class _CounterpartRow extends StatelessWidget {
  const _CounterpartRow({
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

class _VehicleClassChip extends StatelessWidget {
  const _VehicleClassChip({required this.vehicleClass});
  final String vehicleClass;

  (IconData, String) _display(AppL10n l) => switch (vehicleClass) {
        'three_wheeler' => (
            vehicleIconFor(vehicleClass),
            l.vehicleThreeWheeler
          ),
        'four_wheeler' => (vehicleIconFor(vehicleClass), l.vehicleFourWheeler),
        _ => (vehicleIconFor(vehicleClass), l.vehicleTwoWheeler),
      };

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final (icon, label) = _display(l);
    return _DetailRow(icon: icon, label: label);
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
class MapCircleButton extends StatelessWidget {
  const MapCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.iconColor,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  /// Overrides the icon's default color — e.g. Google's own blue for the
  /// external-navigation handoff button, so it reads at a glance as "leaves
  /// the app" rather than blending in with every other map control.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        icon: Icon(icon, color: iconColor),
        tooltip: tooltip,
        onPressed: onTap,
      ),
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

/// While a driver is on an active trip, tracks local GPS continuously (for
/// the driver's own map/nav camera) and posts to the backend roughly every
/// 100m of movement (or every 30s if stationary), rather than on a fixed
/// timer regardless of distance.
class _DriverLocationPublisher extends ConsumerStatefulWidget {
  const _DriverLocationPublisher({required this.tripId});
  final String tripId;

  @override
  ConsumerState<_DriverLocationPublisher> createState() =>
      _DriverLocationPublisherState();
}

class _DriverLocationPublisherState
    extends ConsumerState<_DriverLocationPublisher> {
  // Matches `tripDriverPositionProvider`'s own threshold (trip_ws.dart) — a
  // stopped/crawling driver's GPS heading is noise, not a real turn, and
  // would jitter the nav camera exactly where it most needs to hold steady
  // (waiting at a light).
  static const _minHeadingSpeedMs = 1.0;

  // Other parties (the rider, dispatch) don't need every raw fix — a post
  // roughly every 100m of actual movement is plenty, and cuts backend/
  // battery load compared to posting on a fixed timer regardless of whether
  // the driver has gone anywhere.
  static const _postDistanceMeters = 100.0;
  // A stationary driver (parked, waiting at a light for a while) would
  // otherwise never post again once they stop moving 100m at a time — this
  // keeps the rider's/dispatch's view of the driver from going stale for
  // good while genuinely stopped.
  static const _postKeepAlive = Duration(seconds: 30);
  static const _distance = Distance();

  StreamSubscription<Position>? _sub;
  ProviderSubscription<AsyncValue<double?>>? _compassSub;
  Timer? _keepAliveTimer;
  Timer? _retryTimer;
  ProviderSubscription<AsyncValue<bool>>? _connSub;
  Position? _latest;
  Position? _lastPosted;
  double? _lastHeading;

  /// The device's own magnetometer heading — unlike GPS course-over-ground
  /// (`Position.heading`), this is meaningful even standing still, so it's
  /// what backs [_lastHeading] below [_minHeadingSpeedMs] instead of just
  /// freezing on whatever the last fast-enough GPS fix reported. Google
  /// Maps does the same blend (GPS course while moving, compass while
  /// stopped/crawling) for exactly this reason.
  double? _compassHeading;

  // The most recent position that failed to reach the backend — retried
  // with backoff below, and immediately on reconnect, until it (or a
  // fresher point superseding it) actually lands. Without this a failed
  // ping was just gone for good; the rider/dispatch view of this driver
  // would stay frozen at whatever the last *successful* post was for the
  // entire offline stretch, even after connectivity came back.
  Position? _pendingRetry;
  int _retryAttempt = 0;

  // The position stream itself can die mid-trip — most commonly the OS
  // location permission being revoked live (Android allows this without
  // killing the app) or the GPS toggle turned off. Previously this just
  // silently stopped: no `onError` meant the stream terminated and the
  // driver's marker froze in place for the rest of the trip with no
  // indication anything was wrong. Restarting re-checks permission/service
  // each time, so it recovers on its own the moment either is restored.
  Timer? _streamRestartTimer;

  @override
  void initState() {
    super.initState();
    _start();
    _keepAliveTimer = Timer.periodic(_postKeepAlive, (_) {
      final pos = _latest;
      if (pos != null) _post(pos, previous: _lastPosted);
    });
    _connSub = ref.listenManual(connectivityProvider, (prev, next) {
      // Same in-flight-event-vs-dispose race as the compass listener below.
      if (!mounted) return;
      final backOnline = next.valueOrNull ?? false;
      final pending = _pendingRetry;
      if (backOnline && pending != null) {
        _retryTimer?.cancel();
        _retryAttempt = 0;
        _post(pending, previous: _lastPosted);
      }
    });
  }

  Future<void> _start() async {
    // Not `currentLatLng()` here — it discards everything but lat/lng, and
    // the navigation camera (heading-up rotation) needs `heading`/`speed`
    // too. Same permission/service gating as `currentLatLng()`, just
    // keeping the full `Position`.
    if (!await ensureLocationPermission() ||
        !await Geolocator.isLocationServiceEnabled()) {
      return;
    }
    if (!mounted) return;
    // A continuous local stream, not a poll: `localDriverPositionProvider`
    // (read directly by this driver's own map/nav camera) updates the
    // instant a new fix lands — this is what keeps the driver's own vehicle
    // marker moving offline or on a bad connection, since it no longer
    // depends on `POST location` reaching the backend at all.
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition, onError: (_) => _restartStream(), onDone: _restartStream);
    _compassSub = ref.listenManual(compassHeadingProvider, (prev, next) {
      // `compassHeadingProvider` is a keep-alive, app-lifetime provider — an
      // event can still be in flight the instant this widget's dispose()
      // closes the subscription, landing here just after `ref` is no longer
      // safe to use ("Looking up a deactivated widget's ancestor is
      // unsafe"). `close()` stops *future* events, not one already queued.
      if (!mounted) return;
      final heading = next.valueOrNull;
      if (heading == null) return;
      _compassHeading = heading;
      // `Geolocator.getPositionStream`'s `distanceFilter: 5` above means
      // `_onPosition` (the only other place that writes to
      // `localDriverPositionProvider`) simply never fires while genuinely
      // stationary — exactly the case this compass blend exists for. Without
      // pushing an update from here too, the vehicle icon would keep
      // reading a heading from whatever the last-moving GPS fix reported
      // and never actually visibly turn to face the compass while stopped.
      final pos = _latest;
      if (pos != null && pos.speed <= _minHeadingSpeedMs) {
        _lastHeading = heading;
        ref.read(localDriverPositionProvider.notifier).state = DriverPosition(
          point: LatLng(pos.latitude, pos.longitude),
          heading: _lastHeading,
          speed: pos.speed,
        );
      }
    });
  }

  void _onPosition(Position pos) {
    _latest = pos;
    if (pos.speed > _minHeadingSpeedMs) {
      // Moving fast enough that GPS course-over-ground is trustworthy —
      // preferred over compass here since a moving vehicle's actual heading
      // can differ from wherever the phone itself happens to be pointed
      // (mount angle, being held at an angle, etc.).
      _lastHeading = pos.heading;
    } else if (_compassHeading != null) {
      // Stopped/crawling — GPS course is noise here, but the compass still
      // reads a real heading, so use it instead of freezing on whatever the
      // last fast-enough GPS fix reported.
      _lastHeading = _compassHeading;
    }
    ref.read(localDriverPositionProvider.notifier).state = DriverPosition(
      point: LatLng(pos.latitude, pos.longitude),
      heading: _lastHeading,
      speed: pos.speed,
    );
    final last = _lastPosted;
    final moved = last == null ||
        _distance.as(LengthUnit.Meter, LatLng(last.latitude, last.longitude),
                LatLng(pos.latitude, pos.longitude)) >=
            _postDistanceMeters;
    if (moved) _post(pos, previous: last);
  }

  Future<void> _post(Position pos, {required Position? previous}) async {
    _lastPosted = pos;
    try {
      // `_lastHeading` (GPS course while moving, compass while stopped/
      // crawling) instead of raw `pos.heading` — otherwise this blend would
      // only ever benefit the driver's own screen, and the rider (who only
      // ever sees whatever heading gets posted here) would still get a
      // heading that freezes every time the driver stops.
      await ref.read(rideRepositoryProvider).postLocation(
            widget.tripId,
            pos.latitude,
            pos.longitude,
            heading: _lastHeading,
            speed: pos.speed,
          );
      // A successful post means the backend is caught up — any earlier
      // failed attempt is now moot, since this point is at least as fresh.
      _pendingRetry = null;
      _retryAttempt = 0;
      _retryTimer?.cancel();
    } catch (_) {
      // Offline or a transient failure — the driver's own nav already keeps
      // moving via `localDriverPositionProvider` regardless. Roll back so
      // the next 100m is measured from the last position that actually made
      // it to the backend, not this failed attempt, and keep retrying this
      // point (with backoff, and immediately on reconnect) until it lands.
      _lastPosted = previous;
      _pendingRetry = pos;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final attempt = _retryAttempt++;
    final delaySecs = attempt >= 4 ? 30 : (1 << (attempt + 1)); // 2,4,8,16,30…
    _retryTimer = Timer(Duration(seconds: delaySecs), () {
      final pos = _pendingRetry;
      if (pos != null) _post(pos, previous: _lastPosted);
    });
  }

  void _restartStream() {
    _sub?.cancel();
    _sub = null;
    if (!mounted) return;
    _streamRestartTimer?.cancel();
    _streamRestartTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _compassSub?.close();
    _keepAliveTimer?.cancel();
    _retryTimer?.cancel();
    _streamRestartTimer?.cancel();
    _connSub?.close();
    // Don't leak this trip's last fix into whatever comes next (a new trip,
    // or the driver going idle) — the local nav camera should show nothing
    // until a fresh trip actually starts reporting again.
    ref.read(localDriverPositionProvider.notifier).state = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Invisible: posts the rider's own live GPS to the trip channel (via the
/// same role-agnostic `POST .../location` endpoint [_DriverLocationPublisher]
/// already uses) once they've opted in via [riderShareLocationProvider] —
/// lets the driver see exactly where the rider is instead of only the
/// static pickup pin they selected, useful when the rider is walking to a
/// meeting point or the pin itself is imprecise. Deliberately simpler than
/// [_DriverLocationPublisher]: no compass blend (a walking rider doesn't
/// need a vehicle-accurate heading) and no dedicated retry-with-backoff
/// queue (this is a supplementary display signal, not the trip's
/// authoritative tracking — a missed post is just caught by the next
/// moved-30m fix or the keep-alive tick, no need to chase down one specific
/// failed point the way the driver's own position-of-record does).
class RiderLocationPublisher extends ConsumerStatefulWidget {
  const RiderLocationPublisher({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<RiderLocationPublisher> createState() =>
      _RiderLocationPublisherState();
}

class _RiderLocationPublisherState
    extends ConsumerState<RiderLocationPublisher> {
  // A walking rider moves much slower than a vehicle and precision matters
  // more for a meetup point — tighter than the driver publisher's 100m.
  static const _postDistanceMeters = 30.0;
  static const _postKeepAlive = Duration(seconds: 20);
  static const _distance = Distance();

  StreamSubscription<Position>? _sub;
  Timer? _keepAliveTimer;
  Timer? _streamRestartTimer;
  Position? _latest;
  Position? _lastPosted;

  @override
  void initState() {
    super.initState();
    _start();
    _keepAliveTimer = Timer.periodic(_postKeepAlive, (_) {
      final pos = _latest;
      if (pos != null) _post(pos);
    });
  }

  Future<void> _start() async {
    if (!await ensureLocationPermission() ||
        !await Geolocator.isLocationServiceEnabled()) {
      return;
    }
    if (!mounted) return;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition, onError: (_) => _restartStream(), onDone: _restartStream);
  }

  void _onPosition(Position pos) {
    _latest = pos;
    final last = _lastPosted;
    final moved = last == null ||
        _distance.as(LengthUnit.Meter, LatLng(last.latitude, last.longitude),
                LatLng(pos.latitude, pos.longitude)) >=
            _postDistanceMeters;
    if (moved) _post(pos);
  }

  Future<void> _post(Position pos) async {
    final previous = _lastPosted;
    _lastPosted = pos;
    try {
      await ref.read(rideRepositoryProvider).postLocation(
            widget.tripId,
            pos.latitude,
            pos.longitude,
            heading: pos.heading,
            speed: pos.speed,
          );
    } catch (_) {
      // Roll back so the next moved-30m check is measured from the last
      // position that actually reached the backend, not this failed one —
      // same reasoning as _DriverLocationPublisherState._post. Without this,
      // a single failed post silently rebased the threshold onto a point
      // the backend never saw, swallowing the rider's next 30m of movement
      // until the keep-alive tick happened to catch up.
      _lastPosted = previous;
    }
  }

  void _restartStream() {
    _sub?.cancel();
    _sub = null;
    if (!mounted) return;
    _streamRestartTimer?.cancel();
    _streamRestartTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _keepAliveTimer?.cancel();
    _streamRestartTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Invisible: feeds the rider's own live position + device heading to
/// [localSelfPositionProvider] while there's no driver marker yet to show
/// instead — the rider's "own compass" during the search/pre-assignment
/// phase. Same GPS/compass blend as [_DriverLocationPublisher] but nothing
/// is posted to the backend — this is purely a local display concern, the
/// rider's own location was never something the backend needed.
class _SelfLocationWatcher extends ConsumerStatefulWidget {
  const _SelfLocationWatcher();

  @override
  ConsumerState<_SelfLocationWatcher> createState() =>
      _SelfLocationWatcherState();
}

class _SelfLocationWatcherState extends ConsumerState<_SelfLocationWatcher> {
  static const _minHeadingSpeedMs = 1.0;

  StreamSubscription<Position>? _sub;
  ProviderSubscription<AsyncValue<double?>>? _compassSub;
  Position? _latest;
  double? _compassHeading;
  double? _lastHeading;

  // See `_DriverLocationPublisherState._streamRestartTimer` — without an
  // `onError`/`onDone` handler, a live permission revocation or GPS toggle
  // silently kills this stream and the rider's own position/heading arrow
  // freezes for the rest of the trip.
  Timer? _streamRestartTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (!await ensureLocationPermission() ||
        !await Geolocator.isLocationServiceEnabled()) {
      return;
    }
    if (!mounted) return;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition, onError: (_) => _restartStream(), onDone: _restartStream);
    _compassSub = ref.listenManual(compassHeadingProvider, (prev, next) {
      // Same in-flight-event-vs-dispose race noted on
      // `_DriverLocationPublisherState`'s own compass listener.
      if (!mounted) return;
      final heading = next.valueOrNull;
      if (heading == null) return;
      _compassHeading = heading;
      final pos = _latest;
      if (pos != null && pos.speed <= _minHeadingSpeedMs) {
        _lastHeading = heading;
        ref.read(localSelfPositionProvider.notifier).state = DriverPosition(
          point: LatLng(pos.latitude, pos.longitude),
          heading: _lastHeading,
          speed: pos.speed,
        );
      }
    });
  }

  void _onPosition(Position pos) {
    _latest = pos;
    if (pos.speed > _minHeadingSpeedMs) {
      _lastHeading = pos.heading;
    } else if (_compassHeading != null) {
      _lastHeading = _compassHeading;
    }
    ref.read(localSelfPositionProvider.notifier).state = DriverPosition(
      point: LatLng(pos.latitude, pos.longitude),
      heading: _lastHeading,
      speed: pos.speed,
    );
  }

  void _restartStream() {
    _sub?.cancel();
    _sub = null;
    if (!mounted) return;
    _streamRestartTimer?.cancel();
    _streamRestartTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _compassSub?.close();
    _streamRestartTimer?.cancel();
    ref.read(localSelfPositionProvider.notifier).state = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
