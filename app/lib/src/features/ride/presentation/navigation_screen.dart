import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/offline/connectivity.dart';
import '../../../shared/widgets/common.dart';
import '../application/ride_controller.dart';
import '../application/trip_ws.dart';
import '../domain/models.dart';
import 'trip_screen.dart' show MapCircleButton, vehicleIconFor;
import 'widgets/map_view.dart';

/// Everything [NavigationScreen] needs beyond the trip id, passed through
/// go_router's `extra` — kept in its own class (rather than passing raw
/// positional args through the router) so the route registration in
/// `app_router.dart` doesn't need to know the screen's constructor shape.
class NavigationScreenArgs {
  const NavigationScreenArgs(
      {required this.target, required this.vehicleClass});
  final LatLng target;
  final String vehicleClass;
}

/// Fullscreen, Google-Maps-style turn-by-turn navigation for the driver's
/// current leg. Real maneuvers from the routing engine (Valhalla — see
/// `saarathi_core::routing::RouteStep`), not just a route line: a top banner
/// shows the live "next turn" instruction and distance, a bottom bar shows
/// overall ETA/remaining distance.
///
/// No manual "which step am I on" tracking is needed: [roadRouteProvider] is
/// queried from the driver's own live position to [target] on every GPS
/// ping (same live-rerouting [trip_screen.dart]'s polyline already does), so
/// the freshly-returned route's first step is always "what to do right now
/// from here" — the backend re-derives it, this screen just displays it.
class NavigationScreen extends ConsumerStatefulWidget {
  const NavigationScreen({
    super.key,
    required this.tripId,
    required this.target,
    required this.vehicleClass,
  });

  final String tripId;
  final LatLng target;
  final String vehicleClass;

  @override
  ConsumerState<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends ConsumerState<NavigationScreen> {
  // `roadRouteProvider` is keyed by a `RouteQuery` that embeds the driver's
  // live GPS point, and `LatLng` compares by exact double equality — so
  // practically every ~5s ping is a brand-new `.autoDispose.family` instance
  // with no cached "previous value" to fall back on while it refetches.
  // Reading `.valueOrNull` straight off the provider makes the route line
  // (and the instruction banner, which needs `route.steps`) blink out for
  // that loading window on every single ping. Stashing the last
  // successfully-loaded route here and only overwriting it on a real
  // success means the map keeps showing the last-known route instead.
  RoadRoute? _lastRoute;

  // Re-querying the route on literally every raw GPS ping also means a
  // fresh `.autoDispose.family` provider instance is created and the
  // previous one torn down every ~5s for as long as this screen stays
  // mounted — harmless for a short trip, but the sheer churn over a long
  // navigation session is the leading suspect for a rare dispose-ordering
  // crash seen after staying on this screen a while. Snapping the query
  // point to "the last point we actually queried from, unless the driver's
  // moved far enough that the route would meaningfully differ" keeps the
  // provider family key stable across most pings — cutting churn — while
  // still re-routing promptly on real movement.
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
    final l = AppL10n.of(context);
    final theme = Theme.of(context);
    final online = ref.watch(connectivityProvider).valueOrNull ?? true;
    // This screen is only ever reached by the driver navigating their own
    // trip (see `trip_screen.dart`'s fullscreen button, gated on
    // `iAmDriver`), so it can unconditionally prefer local GPS over the
    // round-tripped WS position — same reasoning as `trip_screen.dart`'s
    // identical merge, and exactly what keeps this screen's own turn-by-turn
    // moving forward while offline instead of freezing.
    final remoteDriverPos =
        ref.watch(tripDriverPositionProvider(widget.tripId)).valueOrNull;
    final localDriverPos = ref.watch(localDriverPositionProvider);
    final driverPos = localDriverPos ?? remoteDriverPos;
    final driverLoc = driverPos?.point;

    final freshRoute = driverLoc == null
        ? null
        : ref
            .watch(roadRouteProvider(RouteQuery(
                [_throttledRoutePoint(driverLoc), widget.target],
                widget.vehicleClass)))
            .valueOrNull;
    if (freshRoute != null) _lastRoute = freshRoute;
    final route = _lastRoute;
    final currentStep =
        (route?.steps.isNotEmpty ?? false) ? route!.steps.first : null;

    return Scaffold(
      body: Stack(
        // `fit: expand` — every child here is `Positioned`, and a couple
        // (the instruction banner) only exist conditionally. A plain Stack
        // with zero *always-present* non-positioned children sizes itself
        // to fit whichever occasional one happens to be there instead of
        // the box Scaffold actually gave it (which is only ever *loose*,
        // not tight — confirmed live via constraint logging: the Scaffold
        // body correctly received the full 0..904 range, but this Stack
        // then collapsed to ~185, matching the instruction banner's own
        // height, leaving the map — genuinely correctly laid out the whole
        // time — painting into a box a fraction of the screen). `expand`
        // forces the Stack itself to the full incoming box regardless of
        // its children's own sizes.
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: MapView(
              center: driverLoc ?? widget.target,
              zoom: 17.5,
              navigationZoom: 18.5,
              route: route?.geometry ?? const [],
              pins: [
                MapPin(widget.target, Icons.sports_score_rounded,
                    theme.colorScheme.secondary),
                if (driverLoc != null)
                  MapPin(
                    driverLoc,
                    vehicleIconFor(widget.vehicleClass),
                    theme.colorScheme.tertiary,
                    rotate: true,
                    id: 'driver',
                  ),
              ],
              navigationTarget: driverPos,
            ),
          ),
          // Own-position/heading only starts updating once the first GPS fix
          // lands — genuinely variable timing (near-instant warm, several
          // seconds cold). Without this, that wait looked identical to a
          // broken compass; confirmed live as an intermittent, hard-to-
          // reproduce "compass doesn't respond" report.
          if (driverLoc == null)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LocatingIndicator(),
                  ),
                ),
              ),
            ),
          if (currentStep != null)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              // `StackFit.expand` above forces non-`Positioned` children to
              // fill the whole stack too, not just the Stack itself — this
              // banner must stay `Positioned` (top-docked) or it stretches
              // to the full screen height instead of hugging its content.
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _InstructionBanner(step: currentStep),
                ),
              ),
            ),
          // Exit + ETA share the bottom edge — thumb-reachable, same
          // placement convention as the map's own locate/recenter buttons —
          // instead of competing with the instruction banner for space up
          // top, which used to crowd the one thing that actually needs to
          // be glanced at while driving.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: MapCircleButton(
                        icon: Icons.close_rounded,
                        tooltip: l.navExit,
                        onTap: () => context.pop(),
                      ),
                    ),
                    if (!online) ...[
                      const SizedBox(width: 10),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: OfflineBanner(),
                      ),
                    ],
                    const SizedBox(width: 10),
                    if (route != null)
                      Expanded(
                        child: _EtaFooter(
                          remainingKm: route.distanceKm,
                          minutesLabel: l
                              .navMinutesLeft((route.durationSecs / 60).ceil()),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "next turn" card — maneuver icon, distance-until, instruction text.
/// Same visual weight Google Maps gives its own top banner: distance is the
/// first thing glanced at, the instruction sentence right under it.
class _InstructionBanner extends StatelessWidget {
  const _InstructionBanner({required this.step});
  final RouteStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(_maneuverIcon(step.maneuver),
                size: 34, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _distanceLabel(step.distanceKm),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    step.instruction,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _distanceLabel(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(km < 10 ? 1 : 0)} km';
  }
}

/// Overall trip-leg progress — remaining distance/ETA, same numbers the
/// regular trip sheet shows, just docked to the bottom of the fullscreen map
/// instead of sharing space with fare/rider details.
class _EtaFooter extends StatelessWidget {
  const _EtaFooter({required this.remainingKm, required this.minutesLabel});
  final double remainingKm;
  final String minutesLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 2))
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            minutesLabel,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.primary,
            ),
          ),
          Text(
            '${remainingKm.toStringAsFixed(1)} km',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

IconData _maneuverIcon(ManeuverKind k) => switch (k) {
      ManeuverKind.depart => Icons.trip_origin_rounded,
      ManeuverKind.arrive => Icons.sports_score_rounded,
      ManeuverKind.straight => Icons.straight_rounded,
      ManeuverKind.slightLeft => Icons.turn_slight_left_rounded,
      ManeuverKind.left => Icons.turn_left_rounded,
      ManeuverKind.sharpLeft => Icons.turn_sharp_left_rounded,
      ManeuverKind.uturnLeft ||
      ManeuverKind.uturnRight =>
        Icons.u_turn_left_rounded,
      ManeuverKind.slightRight => Icons.turn_slight_right_rounded,
      ManeuverKind.right => Icons.turn_right_rounded,
      ManeuverKind.sharpRight => Icons.turn_sharp_right_rounded,
      ManeuverKind.roundabout => Icons.roundabout_left_rounded,
      ManeuverKind.merge => Icons.merge_rounded,
    };
