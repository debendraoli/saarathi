import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/offline/connectivity.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/map_circle_button.dart';
import '../../auth/application/auth_controller.dart';
import '../application/ride_controller.dart';
import '../application/trip_ws.dart';
import '../domain/models.dart';
import 'widgets/bidding_sheet.dart';
import 'widgets/map_view.dart';
import 'widgets/rating_sheet.dart';
import 'widgets/search_radar.dart';
import 'widgets/trip/call_watcher.dart';
import 'widgets/trip/driver_location_publisher.dart';
import 'widgets/trip/rider_location_publisher.dart';
import 'widgets/trip/self_location_watcher.dart';
import 'widgets/trip/status_sheet.dart';
import 'widgets/trip/trip_widgets_shared.dart';

/// Fraction of screen height the bottom status/bidding sheet occupies at
/// rest (its `DraggableScrollableSheet.minChildSize`, see `_StatusSheet`) —
/// map controls that need to sit just above it (locate button, fullscreen
/// nav, back) share this so they dock right at the sheet's collapsed top
/// edge instead of floating with a large, arbitrary gap above it.
const _sheetClearance = 0.32;

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
  // the last one — `route.value` goes null for that loading window on
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

  // Shared with `_StatusSheet`'s `DraggableScrollableSheet` so a double-tap
  // on the map can snap it between its collapsed ("fullscreen" map) and
  // expanded ("card") extents, same two stops the sheet's own drag/snap
  // already has (`snapSizes` in `_StatusSheet.build`) — this is just a
  // shortcut onto the same two states, not a third one.
  final _sheetController = DraggableScrollableController();

  void _toggleSheetFullscreen() {
    final size = _sheetController.isAttached ? _sheetController.size : 0.32;
    _sheetController.animateTo(
      size > 0.5 ? 0.32 : 0.85,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

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
    final online = ref.watch(connectivityProvider).value ?? true;

    // A rider whose driver cancels on them (after having been accepted)
    // otherwise just sits on a "Trip cancelled" status line with no clear
    // next step — this notices the transition and takes them straight back
    // to the booking sheet instead of leaving them to notice and back out
    // manually. Scoped specifically to a driver-initiated cancellation
    // (`cancelledByRole`): the rider's *own* cancel already navigates
    // itself (see `_leaveTrip`/`showCancelReasonSheet`), and re-triggering
    // here too would just double-navigate.
    ref.listen(effectiveTripProvider(tripId), (prev, next) {
      final trip = next.value;
      final prevTrip = prev?.value;
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

    // A trip reaching `completed` previously trapped the rider/driver on
    // this screen — the only way off it was through the "Rate trip" button,
    // so skipping/ignoring rating meant staying stuck here. Now the screen
    // exits (back to wherever it's popped/goes to) the instant the trip
    // completes, and the rating sheet is shown independently on top of
    // whatever's underneath rather than gating that exit.
    ref.listen(effectiveTripProvider(tripId), (prev, next) {
      final trip = next.value;
      final prevTrip = prev?.value;
      if (trip == null || prevTrip == null) return;
      final justCompleted = trip.status == TripStatus.completed &&
          prevTrip.status != TripStatus.completed;
      if (!justCompleted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final myId = ref.read(authControllerProvider).user?.id;
        final iAmDriver = myId != null && myId == trip.driverId;
        // Pushed before navigating below (on the root navigator, so it
        // stays up regardless of which page ends up underneath it) — its
        // result is awaited and posted independently, not blocking the
        // navigation that follows.
        autoRateTrip(
          context,
          ref,
          trip,
          ratingContextFor(trip, iAmDriver),
          TripSummary(
            pickupLabel: ref.read(tripOriginLabelProvider(tripId)).value,
            destLabel: ref.read(tripDestLabelProvider(tripId)).value,
            fare: trip.finalFare,
          ),
        );
        ref.invalidate(myTripsProvider);
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(Routes.home);
        }
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
                      ref.watch(tripDriverPositionProvider(tripId)).value;
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
                      ? ref.watch(tripRiderPositionProvider(tripId)).value
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
                      .value;
                  if (freshRoute != null) _lastRouteGeometry = freshRoute.points;
                  final routeGeometry =
                      _lastRouteGeometry ?? [trip.origin, trip.dest];
                  // Same ETA `EtaFareRow` already shows as sheet text —
                  // also floated right on the map next to the point it's
                  // about, previously visible only by having the sheet
                  // expanded (or knowing to look for it there at all).
                  final routingToPickup = trip.status == TripStatus.accepted ||
                      trip.status == TripStatus.arriving;
                  final etaMins = (routingToPickup ||
                              trip.status == TripStatus.inProgress) &&
                          driverLoc != null
                      ? ref
                          .watch(
                              tripEtaProvider(EtaQuery(driverLoc, routeTarget)))
                          .value
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
                        // A rotating arrow reads as "heading this way" at a
                        // glance, the way Google Maps' own nav puck does — a
                        // vehicle-class silhouette (car/bike/rickshaw) is a
                        // fixed side-profile glyph, so rotating it by
                        // heading just looks like it's spinning in place
                        // rather than pointing anywhere.
                        Icons.navigation_rounded,
                        // Same deliberate blue as the route line and the
                        // rider's own-position arrow below, not
                        // `colorScheme.tertiary` — Material 3's derived
                        // tertiary role from this app's amber/saffron seed
                        // lands in a muted brown/olive tone, which is
                        // exactly what was reported live as an unpolished-
                        // looking marker.
                        routeLineColor,
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
                      // Double-tap the map to snap the status sheet between
                      // its collapsed ("fullscreen" map) and expanded
                      // ("card") extents — the map itself never resizes,
                      // it's always full-bleed underneath; what toggles is
                      // how much of it the sheet covers. `translucent` so
                      // this doesn't steal single-tap gestures the map or
                      // its pins/buttons need (only double-tap is claimed
                      // here).
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onDoubleTap: _toggleSheetFullscreen,
                        child: searching
                            ? SearchRadar(
                                origin: trip.origin,
                                builder: (context, driverPins, circles) =>
                                    MapView(
                                  center: trip.origin,
                                  route: routeGeometry,
                                  circles: circles,
                                  showLocateButton: true,
                                  enableDoubleTapZoom: false,
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
                                enableDoubleTapZoom: false,
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
                      ),
                      // Invisible: routes incoming calls to the call screen.
                      CallWatcher(tripId: tripId),
                      // Invisible: feeds the rider's own "you are here"
                      // arrow above until a driver is assigned.
                      if (iAmRider && driverLoc == null && trip.isActive)
                        const SelfLocationWatcher(),
                      if (!online)
                        const SafeArea(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Padding(
                              padding: EdgeInsets.all(12),
                              child: OfflineBanner(),
                            ),
                          ),
                        ),
                      // Bottom-left, just above the sheet's own collapsed
                      // edge, for one-handed thumb reach — same reasoning
                      // as the fullscreen-nav button below. The actual bug
                      // that made this spot unreliable earlier (a wrong
                      // local trip status hiding trip.isActive-gated
                      // widgets entirely) is fixed at its root now.
                      Positioned(
                        left: 12,
                        bottom: MediaQuery.of(context).size.height *
                                _sheetClearance +
                            12,
                        child: SafeArea(
                          top: false,
                          child: MapCircleButton(
                            icon: Icons.arrow_back_rounded,
                            onTap: () => _leaveTrip(context, ref, tripId),
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
                        DriverLocationPublisher(tripId: tripId),
                      // Invisible: the rider streams their own position once
                      // they've opted in, until pickup (see riderLivePos
                      // above for why it stops mattering after that).
                      if (iAmRider &&
                          trip.isActive &&
                          trip.status != TripStatus.inProgress &&
                          ref.watch(riderShareLocationProvider(tripId)))
                        RiderLocationPublisher(tripId: tripId),
                      // External Google Maps hand-off docks top-right — a
                      // rare, deliberate action, unlike fullscreen nav below
                      // which benefits from being thumb-reachable during an
                      // active trip.
                      if (iAmDriver && trip.isActive)
                        SafeArea(
                          child: Align(
                            alignment: Alignment.topRight,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: MapCircleButton(
                                icon: Icons.navigation_rounded,
                                iconColor: const Color(0xFF4285F4),
                                onTap: () =>
                                    _launchExternalNavigation(routeTarget),
                              ),
                            ),
                          ),
                        ),
                      // Bottom-right, just above the sheet's own collapsed
                      // edge, for one-handed thumb reach during an active
                      // trip — the actual bug that made this spot
                      // unreliable earlier (a wrong local trip status
                      // hiding trip.isActive-gated widgets entirely) is
                      // fixed at its root now; dragging the sheet open past
                      // its collapsed size can still cover this
                      // temporarily, same as any bottom sheet, but it's
                      // never stuck — drag the sheet back down to reveal it.
                      trip.isBidding && trip.status == TripStatus.requested
                          ? BiddingSheet(trip: trip)
                          : StatusSheet(
                              trip: trip,
                              driverLoc: driverLoc,
                              sheetController: _sheetController,
                            ),
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
  final trip = ref.read(tripStreamProvider(tripId)).value;
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
