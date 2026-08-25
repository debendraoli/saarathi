import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/location.dart';
import '../../application/trip_ws.dart' show DriverPosition;

/// A pin to render on the map.
class MapPin {
  const MapPin(this.point, this.icon, this.color, {this.rotate = false, this.id, this.label});
  final LatLng point;
  final IconData icon;
  final Color color;

  /// Keep this pin screen-fixed (pointing "up") regardless of map rotation —
  /// for a directional icon (the driver's nav arrow) on a heading-up map.
  /// Plain location pins (pickup/destination) leave this false so they
  /// rotate with the map like everything else.
  final bool rotate;

  /// Stable identity ("pickup", "stop-0", "dest", …) used to key the marker
  /// widget so its entrance animation plays once per pin, not on every map
  /// rebuild — a route recalculation or fare tick shouldn't replay the pop-in
  /// for pins that were already there. Pins sharing an id are treated as
  /// "the same pin, possibly moved" (animates position, not a fresh pop-in);
  /// pins with no id fall back to list position for identity.
  final String? id;

  /// When set, renders as a small numbered badge (stop order, "1"/"2"/…)
  /// instead of [icon] — how the rider tells stops apart on the map.
  final String? label;
}


/// A floating "arrive at HH:MM" (or similar) label anchored above a point —
/// e.g. the destination pin, showing the ETA the fare estimate already
/// computed, the way Yango/Uber float it right on the map.
class MapCallout {
  const MapCallout({required this.point, required this.text});
  final LatLng point;
  final String text;
}

/// A geographic circle (radius in meters, so it scales/pans correctly with
/// the map) — used for the search-radius "ping" rings.
class MapCircle {
  const MapCircle({
    required this.center,
    required this.radiusMeters,
    required this.color,
    required this.borderColor,
    this.borderStrokeWidth = 1.5,
  });
  final LatLng center;
  final double radiusMeters;
  final Color color;
  final Color borderColor;
  final double borderStrokeWidth;
}

/// Reusable OSM map (self-hosted tiles in prod; public OSM in dev). Optional tap
/// callback for picking a point, and a pin list for pickup/destination/driver.
class MapView extends StatefulWidget {
  const MapView({
    super.key,
    required this.center,
    this.zoom = 14,
    this.pins = const [],
    this.route = const [],
    this.circles = const [],
    this.onTap,
    this.controller,
    this.showLocateButton = false,
    this.locateButtonBottomOffset = 16,
    this.navigationTarget,
    this.navigationZoom = 17.5,
    this.autoFitPins = false,
    this.fitPadding = const EdgeInsets.fromLTRB(48, 96, 48, 320),
    this.showRecenterButton = false,
    this.callouts = const [],
  });

  final LatLng center;
  final double zoom;
  final List<MapPin> pins;
  final List<LatLng> route;
  final List<MapCircle> circles;
  final void Function(LatLng)? onTap;
  final MapController? controller;

  /// Floating "arrive at HH:MM"-style labels anchored above a point.
  final List<MapCallout> callouts;

  /// When set, this widget drives its own camera — smoothly panning, zooming
  /// to [navigationZoom], and rotating heading-up to follow this position
  /// (turn-by-turn style) instead of the static [center]/[zoom] it would
  /// otherwise just use once, on first build.
  final DriverPosition? navigationTarget;
  final double navigationZoom;

  /// Shows a floating "recenter on my location" button, bottom-right — off
  /// by default so screens that already manage their own map overlays there
  /// (or don't want one, e.g. a small preview map) aren't affected.
  /// Bottom (not top) so it's reachable one-handed, thumb-distance from
  /// wherever the hand is already holding the phone.
  final bool showLocateButton;

  /// Extra space to leave above the bottom edge, e.g. to clear a bottom
  /// sheet's collapsed height so the button isn't sitting under it.
  final double locateButtonBottomOffset;

  /// When true, the camera smoothly zooms/pans to keep every pin in
  /// [pins] visible whenever their positions change (2+ pins) — the
  /// "route planning" camera behavior for pickup/stops/destination. Off by
  /// default: screens mid-trip (driver-following, turn-by-turn) manage their
  /// own camera via [navigationTarget] instead and would fight this.
  final bool autoFitPins;

  /// Screen-space padding kept clear around the fitted pins — the larger
  /// bottom value leaves room for a booking sheet sitting over the map.
  final EdgeInsets fitPadding;

  /// Shows a floating "recenter on route" button, top-right — snaps back to
  /// fitting every pin on screen after the rider has panned/zoomed away.
  /// Only meaningful alongside [autoFitPins]/2+ [pins].
  final bool showRecenterButton;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with TickerProviderStateMixin {
  static const _osmFallback = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  late final MapController _controller = widget.controller ?? MapController();
  bool _locating = false;

  AnimationController? _navAnim;
  AnimationController? _fitAnim;
  List<LatLng>? _lastFitPoints;

  AnimationController? _routeAnim;
  List<LatLng> _revealedRoute = const [];
  List<LatLng>? _lastRoute;

  @override
  void initState() {
    super.initState();
    final target = widget.navigationTarget;
    if (target != null) {
      // First frame: snap straight there, nothing to animate from yet.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.moveAndRotate(
            target.point,
            widget.navigationZoom,
            _mapRotationFor(target.heading) ?? 0,
          );
        }
      });
    } else if (widget.autoFitPins) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFitPins());
    }
    _revealedRoute = widget.route;
    _lastRoute = widget.route;
    _lastFitPoints = _fittablePoints();
  }

  @override
  void didUpdateWidget(covariant MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.navigationTarget;
    if (target != null) {
      final prev = oldWidget.navigationTarget;
      if (prev == null ||
          prev.point != target.point ||
          prev.heading != target.heading) {
        _animateTo(target);
      }
    } else if (widget.autoFitPins) {
      _maybeFitPins();
    }
    if (!listEquals(widget.route, _lastRoute)) {
      _lastRoute = widget.route;
      _animateRouteReveal(widget.route);
    }
  }

  /// flutter_map's `rotation` is how much the map content itself is turned;
  /// to make a compass [heading] point "up" on screen, the content has to
  /// turn the opposite way. (Sign flipped here rather than in the caller —
  /// easy single-line fix if it ever reads backwards on a real device.)
  double? _mapRotationFor(double? heading) => heading == null ? null : -heading;

  void _animateTo(DriverPosition target) {
    final toRotationRaw =
        _mapRotationFor(target.heading) ?? _controller.camera.rotation;
    _navAnim?.dispose();
    _animateCamera(
      toCenter: target.point,
      toZoom: widget.navigationZoom,
      toRotation: toRotationRaw,
      controllerSlot: (c) => _navAnim = c,
    );
  }

  /// The set of points the camera should keep visible — every current pin's
  /// position. `null`/empty when there's nothing worth fitting to yet.
  ///
  /// Drops exact (0, 0) — "Null Island" is never a legitimate pickup/stop/
  /// destination for this app, only ever a sign an upstream point hasn't
  /// resolved yet; including it would blow the fit bounds out to a
  /// whole-world view instead of just waiting for the real coordinate.
  List<LatLng>? _fittablePoints() {
    if (widget.pins.length < 2) return null;
    final points = [
      for (final p in widget.pins)
        if (p.point.latitude != 0 || p.point.longitude != 0) p.point,
    ];
    return points.length < 2 ? null : points;
  }

  /// Smoothly zooms/pans to fit every pin on screen, re-fitting only when the
  /// actual point set changed (not on every unrelated rebuild) — unless
  /// [force], which the recenter button uses to snap back even when nothing
  /// about the pins themselves has changed (the rider just panned away).
  void _maybeFitPins({bool force = false}) {
    final points = _fittablePoints();
    if (points == null) return;
    if (!force && _lastFitPoints != null && listEquals(points, _lastFitPoints)) {
      return;
    }
    _lastFitPoints = points;

    // Guard the whole computation: `CameraFit` doing this math against a
    // degenerate padding/bounds combination (e.g. the sheet growing tall
    // enough that top+bottom padding leaves ~0 usable height) can silently
    // hand back a NaN/Infinite zoom rather than throwing — and feeding that
    // into moveAndRotate is exactly what was corrupting the map into a
    // permanently blank state (confirmed live: tiles AND markers both
    // vanish, since both need a finite camera to project against). Treat
    // any non-finite result as "can't fit this, leave the camera alone"
    // instead of ever applying it.
    // CameraFit.bounds (a plain LatLngBounds fit) rather than
    // CameraFit.coordinates — the latter was observed live zooming out far
    // wider than the actual point spread justified (a ~2km route rendering
    // at district-wide zoom), consistent with its rotation-aware corner
    // math computing a much larger effective bounding box than the points'
    // own bounds. Plain bounds-fit is the standard, predictable behavior.
    MapCamera fitted;
    try {
      fitted = CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(points),
        padding: widget.fitPadding,
      ).fit(_controller.camera);
    } catch (_) {
      return;
    }
    // A little extra breathing room beyond the tightest fit, so pins don't
    // sit flush against their padding box — reads as "zoomed out enough to
    // orient", not "zoomed to the exact edge of the route". The lower clamp
    // bound is well above a literal world view — this app only ever
    // operates within one city/country, so a route never legitimately
    // needs to zoom out further than that.
    const extraZoomOut = 0.4;
    final targetZoom = (fitted.zoom - extraZoomOut).clamp(10.0, 19.0);
    if (!fitted.center.latitude.isFinite ||
        !fitted.center.longitude.isFinite ||
        !targetZoom.isFinite) {
      return;
    }
    _fitAnim?.dispose();
    _animateCamera(
      toCenter: fitted.center,
      toZoom: targetZoom,
      controllerSlot: (c) => _fitAnim = c,
    );
  }

  /// Shared camera tween used by both driver-follow ([_animateTo]) and
  /// fit-to-pins ([_maybeFitPins]) — only the destination differs.
  void _animateCamera({
    required LatLng toCenter,
    required double toZoom,
    double? toRotation,
    required void Function(AnimationController?) controllerSlot,
    Duration duration = const Duration(milliseconds: 600),
  }) {
    // Never animate toward (or from) a non-finite value — a bad target
    // silently corrupts the map's camera into a permanently blank state
    // (no tiles, no markers), so this is the last line of defense even
    // though callers are expected to have already validated their target.
    if (!toCenter.latitude.isFinite ||
        !toCenter.longitude.isFinite ||
        !toZoom.isFinite) {
      return;
    }
    final camera = _controller.camera;
    var fromCenter = camera.center;
    var fromZoom = camera.zoom;
    if (!fromCenter.latitude.isFinite ||
        !fromCenter.longitude.isFinite ||
        !fromZoom.isFinite) {
      // The camera itself is already in a bad state (shouldn't happen now,
      // but this is the recovery path if it ever does) — snap straight to
      // the target instead of animating from garbage.
      fromCenter = toCenter;
      fromZoom = toZoom;
    }
    final fromRotation = camera.rotation.isFinite ? camera.rotation : 0.0;
    double targetRotation = fromRotation;
    if (toRotation != null) {
      // Shortest angular path — don't spin 350° the long way round for
      // what's really a 10° turn.
      var delta = (toRotation - fromRotation) % 360;
      if (delta > 180) delta -= 360;
      if (delta < -180) delta += 360;
      targetRotation = fromRotation + delta;
    }

    final anim = AnimationController(vsync: this, duration: duration);
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
    curved.addListener(() {
      if (!mounted) return;
      final t = curved.value;
      final lat = fromCenter.latitude + (toCenter.latitude - fromCenter.latitude) * t;
      final lng = fromCenter.longitude + (toCenter.longitude - fromCenter.longitude) * t;
      final zoom = fromZoom + (toZoom - fromZoom) * t;
      final rotation = fromRotation + (targetRotation - fromRotation) * t;
      _controller.moveAndRotate(LatLng(lat, lng), zoom, rotation);
    });
    controllerSlot(anim);
    anim.forward();
  }

  /// Draws the route line as a "reveal" — a snake growing from the pickup
  /// end to the destination end — instead of popping in fully formed the
  /// instant a route arrives (straight-line guess, then the real routed
  /// geometry once it lands).
  void _animateRouteReveal(List<LatLng> target) {
    _routeAnim?.dispose();
    if (target.length < 2) {
      setState(() => _revealedRoute = target);
      return;
    }
    final anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
    curved.addListener(() {
      if (!mounted) return;
      setState(() => _revealedRoute = _tracePrefix(target, curved.value));
    });
    _routeAnim = anim;
    anim.forward();
  }

  /// The leading portion of [points] covering fraction [t] of the total
  /// line length (0 = nothing drawn, 1 = the whole route) — a straight
  /// index cutoff would make the reveal speed uneven across long/short
  /// segments, so this walks by cumulative distance instead.
  List<LatLng> _tracePrefix(List<LatLng> points, double t) {
    if (t >= 1) return points;
    if (t <= 0) return [points.first];
    const dist = Distance();
    final segLengths = [
      for (var i = 0; i < points.length - 1; i++)
        dist.as(LengthUnit.Meter, points[i], points[i + 1]),
    ];
    final total = segLengths.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return points;
    final targetDist = total * t;
    final out = <LatLng>[points.first];
    var covered = 0.0;
    for (var i = 0; i < segLengths.length; i++) {
      final segLen = segLengths[i];
      if (covered + segLen >= targetDist) {
        final segT = segLen == 0 ? 0.0 : (targetDist - covered) / segLen;
        final a = points[i];
        final b = points[i + 1];
        out.add(LatLng(
          a.latitude + (b.latitude - a.latitude) * segT,
          a.longitude + (b.longitude - a.longitude) * segT,
        ));
        return out;
      }
      covered += segLen;
      out.add(points[i + 1]);
    }
    return out;
  }

  @override
  void dispose() {
    _navAnim?.dispose();
    _fitAnim?.dispose();
    _routeAnim?.dispose();
    super.dispose();
  }

  /// Builds one marker, keyed by the pin's stable identity so its pop-in
  /// animation ([_PopInMarker]) plays once when the pin first appears and
  /// never replays on an unrelated rebuild (a fare tick, a route refresh).
  Marker _markerFor(MapPin pin, int index) {
    return Marker(
      key: ValueKey(pin.id ?? 'pin-$index'),
      point: pin.point,
      width: 44,
      height: 44,
      alignment: Alignment.topCenter,
      rotate: pin.rotate,
      child: _PopInMarker(
        child: pin.label != null
            ? _NumberedPin(label: pin.label!, color: pin.color)
            : Icon(pin.icon, color: pin.color, size: 38),
      ),
    );
  }

  /// An "arrive at HH:MM" pill floating above [callout.point] — wide enough
  /// for the text, so unlike the fixed-size pin markers this sizes itself
  /// and centers on its point rather than pointing up from below it.
  Marker _calloutMarker(MapCallout callout) {
    return Marker(
      key: ValueKey('callout-${callout.point.latitude}-${callout.point.longitude}'),
      point: callout.point,
      width: 120,
      height: 34,
      alignment: const Alignment(0, -2.6),
      child: _PopInMarker(
        child: Material(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              callout.text,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _locateMe() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final here = await currentLatLng();
      _controller.move(here, _controller.camera.zoom);
    } catch (_) {
      // No location available (permission denied, GPS off) — nothing more
      // to do; the button just doesn't move the map this time.
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tileUrl = AppConfig.tileUrlTemplate.isNotEmpty
        ? AppConfig.tileUrlTemplate
        : _osmFallback;
    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: widget.center,
            initialZoom: widget.zoom,
            onTap: widget.onTap == null ? null : (_, p) => widget.onTap!(p),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom |
                  InteractiveFlag.drag |
                  InteractiveFlag.doubleTapZoom,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: tileUrl,
              userAgentPackageName: 'com.saarathi.app',
              maxZoom: 19,
            ),
            if (widget.circles.isNotEmpty)
              CircleLayer(
                circles: [
                  for (final c in widget.circles)
                    CircleMarker(
                      point: c.center,
                      radius: c.radiusMeters,
                      useRadiusInMeter: true,
                      color: c.color,
                      borderColor: c.borderColor,
                      borderStrokeWidth: c.borderStrokeWidth,
                    ),
                ],
              ),
            if (_revealedRoute.length >= 2)
              PolylineLayer(
                polylines: [
                  // Blue route line — the brand saffron collides with OSM road/POI colors.
                  Polyline(
                    points: _revealedRoute,
                    strokeWidth: 5,
                    color: const Color(0xFF1A73E8),
                    borderStrokeWidth: 1.5,
                    borderColor: Colors.white,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                for (var i = 0; i < widget.pins.length; i++)
                  _markerFor(widget.pins[i], i),
                for (final c in widget.callouts) _calloutMarker(c),
              ],
            ),
          ],
        ),
        if (widget.showLocateButton)
          Positioned(
            bottom: widget.locateButtonBottomOffset,
            right: 12,
            child: SafeArea(
              top: false,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                shape: const CircleBorder(),
                elevation: 2,
                child: IconButton(
                  onPressed: _locateMe,
                  icon: _locating
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        )
                      : const Icon(Icons.my_location_rounded),
                ),
              ),
            ),
          ),
        if (widget.showRecenterButton)
          Positioned(
            top: 8,
            right: 12,
            child: SafeArea(
              bottom: false,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                shape: const CircleBorder(),
                elevation: 2,
                child: IconButton(
                  tooltip: 'Recenter',
                  onPressed: () => _maybeFitPins(force: true),
                  icon: const Icon(Icons.route_rounded),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A one-shot "drop in" for a newly-appeared marker — scales up past 100%
/// and settles, rather than the pin just materializing. Runs exactly once
/// per [State] lifetime; callers keep that lifetime stable per pin by
/// keying the enclosing [Marker] with the pin's identity (see
/// `_MapViewState._markerFor`), so this doesn't replay on unrelated rebuilds.
class _PopInMarker extends StatefulWidget {
  const _PopInMarker({required this.child});
  final Widget child;

  @override
  State<_PopInMarker> createState() => _PopInMarkerState();
}

class _PopInMarkerState extends State<_PopInMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..forward();
  late final Animation<double> _scale =
      CurvedAnimation(parent: _c, curve: Curves.elasticOut);
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.4, curve: Curves.easeOut),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      alignment: Alignment.bottomCenter,
      child: FadeTransition(opacity: _fade, child: widget.child),
    );
  }
}

/// A small numbered badge for a stop pin ("1", "2", …) — how the rider
/// tells multi-stop order apart on the map, matching the order they added
/// them in the sheet.
class _NumberedPin extends StatelessWidget {
  const _NumberedPin({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
            ],
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 13,
              height: 1,
            ),
          ),
        ),
        // A short pointer down to the actual coordinate, since the badge
        // itself (unlike the icon pins) has no natural "tip".
        CustomPaint(size: const Size(10, 6), painter: _PinTailPainter(color)),
      ],
    );
  }
}

class _PinTailPainter extends CustomPainter {
  const _PinTailPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PinTailPainter oldDelegate) =>
      oldDelegate.color != color;
}
