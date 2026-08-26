import 'dart:async';
import 'dart:math' show pi;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/location.dart';
import '../../application/trip_ws.dart' show DriverPosition;

/// The route line's own blue — the brand saffron collides with OSM road/POI
/// colors on the tile layer. Pickup/destination pins share it too, so a
/// trip's whole path (pins + line) reads as one consistent visual, not
/// mismatched brand-color pins against a blue line.
const routeLineColor = Color(0xFF1A73E8);

/// Persists fetched tiles to disk via flutter_map's own built-in caching
/// (on by default for `NetworkTileProvider` — nothing extra to add as a
/// dependency), but with freshness forced to a long fixed window instead of
/// trusting the self-hosted tile server's own HTTP cache headers.
///
/// Without `overrideFreshAge`, the built-in cache still *stores* every
/// tile, but treats freshness however the server's `Cache-Control`/`Expires`
/// headers say to — and our self-hosted server doesn't set those
/// meaningfully, so every tile view still triggered a full re-fetch despite
/// bytes already sitting on disk. That's the actual cause of the blurry
/// upscaled-placeholder-then-sharpen flicker reported live on a fresh trip
/// screen and even the fullscreen nav view: it isn't that caching was
/// missing, it's that the cache never considered anything fresh. Road
/// layout is stable enough that a stale tile from last week is still the
/// right tile — that's the whole point of raising this rather than fixing
/// the tile server's headers, which we don't control end-to-end (public OSM
/// fallback included).
///
/// A single shared instance (not per-`MapView`) so every screen's map draws
/// from — and writes to — the same on-disk cache; this is also why a route
/// seen once (during a ride, or even a previous app run before a crash) is
/// immediately available again without a network round trip.
final _tileProvider = NetworkTileProvider(
  cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(
    overrideFreshAge: const Duration(days: 30),
  ),
);

/// A pin to render on the map.
class MapPin {
  const MapPin(this.point, this.icon, this.color,
      {this.rotate = false, this.heading, this.id, this.label});
  final LatLng point;
  final IconData icon;
  final Color color;

  /// Keep this pin screen-fixed (pointing "up") regardless of map rotation —
  /// for a directional icon (the driver's nav arrow) on a heading-up map
  /// (`MapView.rotateMap: true`, the fullscreen turn-by-turn screen). Plain
  /// location pins (pickup/destination) leave this false so they rotate with
  /// the map like everything else.
  final bool rotate;

  /// Bearing (degrees, 0-360) to rotate this pin's icon by directly — for a
  /// directional icon on a map that *isn't* itself rotating
  /// (`MapView.rotateMap: false`), so the icon visibly turns in place to
  /// face the reported heading instead of relying on the map spinning
  /// underneath a screen-fixed glyph. Combining this with [rotate]`: true`
  /// on a rotating map isn't meaningful — pick one scheme per screen.
  final double? heading;

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
    this.rotateMap = true,
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

  /// Whether [navigationTarget]'s heading rotates the map itself (heading-up
  /// nav, screen-fixed vehicle icon) — the fullscreen turn-by-turn screen's
  /// scheme. `false` keeps the map north-up and leaves camera-follow/
  /// look-ahead panning intact, for a screen that instead rotates the
  /// vehicle *icon* itself via `MapPin.heading` (e.g. the in-trip map, so
  /// it doesn't spin the whole map under a rider just watching it).
  final bool rotateMap;

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

  /// Shows a single floating nav button, bottom-right (same slot
  /// [showLocateButton] would use — don't set both on the same screen):
  /// centers on the rider's live GPS by default, and swaps to "back to
  /// route" (re-fitting every pin) once they've panned/zoomed far enough
  /// from the fitted route that the route is the more useful target.
  /// Meaningful alongside [autoFitPins]/2+ [pins]; harmless without it —
  /// the button just always acts as "my location".
  final bool showRecenterButton;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with TickerProviderStateMixin {
  static const _osmFallback = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  late final MapController _controller = widget.controller ?? MapController();
  bool _locating = false;

  // Persistent, created once and reused for the whole widget lifetime — see
  // [_retargetNavAnimation]'s doc comment for why this doesn't dispose and
  // recreate a controller on every retarget the way [_animateCamera]
  // (still used by [_maybeFitPins]) does.
  AnimationController? _navAnimCtrl;
  LatLng? _navFromCenter, _navToCenter;
  double _navFromZoom = 0, _navToZoom = 0;
  double _navFromRotation = 0, _navToRotation = 0;

  AnimationController? _fitAnim;
  List<LatLng>? _lastFitPoints;
  Timer? _resizeFitDebounce;
  Timer? _resizeNavDebounce;

  /// True once the rider has panned/zoomed far enough from the fitted route
  /// that the combined nav button should offer "back to route" instead of
  /// "my location" — see [_navButtonIcon].
  bool _awayFromRoute = false;

  AnimationController? _routeAnim;
  List<LatLng> _revealedRoute = const [];
  List<LatLng>? _lastRoute;

  /// How long a moving pin (the live driver marker) takes to glide from its
  /// last displayed position to a newly-arrived one — a touch under the
  /// ~5s GPS ping cadence so it settles before the next ping lands, instead
  /// of perpetually chasing a moving target.
  static const _pinMoveDuration = Duration(milliseconds: 4200);

  /// How far ahead of the driver's live position the nav camera centers,
  /// in the direction of travel — the same "look-ahead" Google Maps uses so
  /// the vehicle sits toward the bottom of the screen with more upcoming
  /// road visible, instead of dead-centered. Only applied when a heading is
  /// available (nothing to look "ahead" of otherwise).
  static const _lookAheadMeters = 45.0;

  static const _distance = Distance();

  /// A newly-reported point further than this from where a pin/camera was
  /// last displayed is treated as "this screen was away for a while" (the
  /// classic case: `TripScreen`'s own `MapView` sits covered underneath the
  /// fullscreen `NavigationScreen`, which keeps polling/gliding independently
  /// while covered — by the time you pop back, the covered map's last
  /// displayed position can be many pings stale) rather than a normal single
  /// GPS ping's worth of movement. Animating that whole accumulated gap at
  /// the usual glide speed would look like the vehicle slowly crawling to
  /// catch up over several seconds instead of just being where it actually
  /// is — confirmed live: "the vehicle arriving to the location takes so
  /// long when exited from fullscreen".
  static const _bigJumpMeters = 150.0;

  /// Currently-displayed position for each identified, moving pin — lags
  /// behind [MapPin.point] while an in-flight glide animation closes the
  /// gap. Pins without an [MapPin.id] just render at their literal point,
  /// same as before (only the driver marker opts into this today).
  final Map<String, LatLng> _pinDisplay = {};
  final Map<String, AnimationController> _pinAnims = {};

  @override
  void initState() {
    super.initState();
    final target = widget.navigationTarget;
    if (target != null) {
      // First frame: snap straight there, nothing to animate from yet.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.moveAndRotate(
            _lookAheadCenter(target),
            widget.navigationZoom,
            _mapRotationFor(target.heading) ?? 0,
          );
        }
      });
    } else if (widget.autoFitPins) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFitPins());
    }
    // NOTE: a fullscreen nav route (see NavigationScreen) can leave
    // flutter_map's own tile viewport stuck small — the outer
    // Positioned.fill/Stack/Scaffold is genuinely full-screen from frame
    // one (confirmed with a diagnostic background), but flutter_map only
    // paints tiles for a small region and never catches up. A delayed
    // `_controller.moveAndRotate`/`.move()` correction pass was tried here
    // and reliably made things *worse* — reproduced live, racing against
    // the concurrent `_animateTo` tween corrupted the map into a mirrored/
    // rotated state and reintroduced a `_dependents.isEmpty` framework
    // crash. Left unfixed rather than risk that again; needs a real fix
    // (e.g. an explicit flutter_map API to force a remeasure, if one
    // exists) rather than another blind direct-controller workaround.
    _revealedRoute = widget.route;
    _lastRoute = widget.route;
    _lastFitPoints = _fittablePoints();
    for (final p in widget.pins) {
      if (p.id != null) _pinDisplay[p.id!] = p.point;
    }
  }

  @override
  void didUpdateWidget(covariant MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.navigationTarget;
    if (target != null) {
      final prev = oldWidget.navigationTarget;
      if (prev == null ||
          prev.point != target.point ||
          _headingChangedEnough(prev.heading, target.heading)) {
        _animateTo(target);
      }
    } else if (widget.autoFitPins) {
      _maybeFitPins();
    }
    _syncMovingPins(oldWidget.pins, widget.pins);
    if (!listEquals(widget.route, _lastRoute)) {
      final prevRoute = _lastRoute;
      _lastRoute = widget.route;
      _animateRouteReveal(widget.route, prevRoute);
    }
  }

  /// Glides each identified pin (the live driver marker) from wherever it's
  /// currently displayed to its newly-reported point, instead of snapping
  /// there instantly the moment a fresh GPS ping arrives — a ping lands
  /// roughly every 5s, far too coarse to read as continuous motion without
  /// this, and made the whole marker look like it was "re-rendering" in
  /// place rather than driving along the road.
  void _syncMovingPins(List<MapPin> oldPins, List<MapPin> newPins) {
    final newIds = <String>{};
    for (final pin in newPins) {
      final id = pin.id;
      if (id == null) continue;
      newIds.add(id);
      final from = _pinDisplay[id];
      if (from == null) {
        // First time this id has been seen — nothing to glide from, and
        // the marker's own pop-in animation already covers its arrival.
        _pinDisplay[id] = pin.point;
        continue;
      }
      if (from == pin.point) continue;
      if (_distance.as(LengthUnit.Meter, from, pin.point) > _bigJumpMeters) {
        _pinAnims.remove(id)?.dispose();
        _pinDisplay[id] = pin.point;
        continue;
      }
      _animatePinTo(id, from, pin.point);
    }
    // A pin that's gone (e.g. the driver marker once the trip ends) drops
    // its remembered position, so if the same id ever reappears later it
    // starts fresh instead of gliding in from a stale, unrelated spot.
    _pinDisplay.removeWhere((id, _) => !newIds.contains(id));
    for (final id in _pinAnims.keys.toList()) {
      if (!newIds.contains(id)) {
        _pinAnims.remove(id)?.dispose();
      }
    }
  }

  void _animatePinTo(String id, LatLng from, LatLng to) {
    _pinAnims.remove(id)?.dispose();
    final anim = AnimationController(vsync: this, duration: _pinMoveDuration);
    // Linear, not eased — a vehicle moves at roughly constant speed between
    // two GPS fixes; an ease-in/out here would read as slowing down to
    // stop at every single ping, which isn't what's happening.
    anim.addListener(() {
      if (!mounted) return;
      final t = anim.value;
      setState(() {
        _pinDisplay[id] = LatLng(
          from.latitude + (to.latitude - from.latitude) * t,
          from.longitude + (to.longitude - from.longitude) * t,
        );
      });
    });
    _pinAnims[id] = anim;
    anim.forward();
  }

  /// flutter_map's `rotation` is how much the map content itself is turned;
  /// to make a compass [heading] point "up" on screen, the content has to
  /// turn the opposite way. (Sign flipped here rather than in the caller —
  /// easy single-line fix if it ever reads backwards on a real device.)
  double? _mapRotationFor(double? heading) =>
      (!widget.rotateMap || heading == null) ? null : -heading;

  /// The point the camera should actually center on for a given driver
  /// position — offset ahead of the raw GPS point in the direction of
  /// travel (see [_lookAheadMeters]) so the vehicle sits toward the bottom
  /// of the screen with more of the upcoming road visible, matching Google
  /// Maps' turn-by-turn framing instead of dead-centering the marker.
  LatLng _lookAheadCenter(DriverPosition target) {
    final heading = target.heading;
    if (heading == null) return target.point;
    return _distance.offset(target.point, _lookAheadMeters, heading);
  }

  /// Whether two headings differ enough to be worth restarting the camera
  /// glide for. The device compass fires many times a second — confirmed
  /// live, well over 10/s even while genuinely stationary — and without
  /// this threshold, every single one of those (sub-degree, pure sensor
  /// noise) ticks tore down and rebuilt [_animateTo]'s `AnimationController`
  /// via [didUpdateWidget]. That churn is what actually produced the
  /// symptoms reported live during "moving/testing the compass": a
  /// momentarily flipped-looking marker and, in the worst case, a
  /// `_dependents.isEmpty` framework crash — not a rotation-math bug (the
  /// shortest-angular-path handling in [_animateCamera] was already
  /// correct), but sheer per-frame animation-controller pressure on top of
  /// everything else already rebuilding (GPS pin glides, position state).
  bool _headingChangedEnough(double? a, double? b) {
    if (a == null || b == null) return a != b;
    var delta = (b - a) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    return delta.abs() > 3;
  }

  void _animateTo(DriverPosition target) {
    final toRotationRaw =
        _mapRotationFor(target.heading) ?? _controller.camera.rotation;
    final toCenter = _lookAheadCenter(target);
    final camera = _controller.camera;
    final currentCenterValid =
        camera.center.latitude.isFinite && camera.center.longitude.isFinite;
    if (currentCenterValid &&
        _distance.as(LengthUnit.Meter, camera.center, toCenter) >
            _bigJumpMeters) {
      // Same "this screen was covered/away for a while" case as the pin
      // glide above — panning the whole accumulated gap at the usual speed
      // would look like a slow, unrealistic crawl instead of the camera
      // just being where the driver actually is.
      _navAnimCtrl?.stop();
      _controller.moveAndRotate(toCenter, widget.navigationZoom, toRotationRaw);
      return;
    }
    _retargetNavAnimation(
      toCenter: toCenter,
      toZoom: widget.navigationZoom,
      toRotation: toRotationRaw,
    );
  }

  /// Retargets the persistent nav-follow animation instead of disposing and
  /// creating a fresh `AnimationController` (what [_animateCamera] below
  /// still does, fine for [_maybeFitPins]'s much lower call rate). This one
  /// backs [_animateTo], which the fullscreen turn-by-turn screen calls on
  /// every `navigationTarget` update — and the device compass fires many
  /// times a second even stationary. Disposing+recreating a controller (and
  /// its listener closure) that often was reliably producing a
  /// `_dependents.isEmpty` framework crash, confirmed live even after
  /// throttling restarts to only >3° heading changes — the churn itself,
  /// not just its frequency, was the problem. One controller for this
  /// widget's whole lifetime, just re-`forward(from: 0)`'d with new
  /// from/to values on each call, has no dispose/recreate cycle left to
  /// race on at all.
  void _retargetNavAnimation({
    required LatLng toCenter,
    required double toZoom,
    required double toRotation,
  }) {
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
      fromCenter = toCenter;
      fromZoom = toZoom;
    }
    final fromRotation = camera.rotation.isFinite ? camera.rotation : 0.0;
    // Shortest angular path — same reasoning as `_animateCamera`.
    var delta = (toRotation - fromRotation) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;

    _navFromCenter = fromCenter;
    _navToCenter = toCenter;
    _navFromZoom = fromZoom;
    _navToZoom = toZoom;
    _navFromRotation = fromRotation;
    _navToRotation = fromRotation + delta;

    // Deliberately shorter than `_pinMoveDuration` (the marker's own glide,
    // which stays linear/full-duration) — raster map tiles blur while
    // actively panning/rotating (confirmed live: sharpens the instant a
    // manual drag interrupts it), and matching the camera's glide to the
    // *entire* ~4.2s inter-ping gap left it almost permanently mid-motion,
    // so it was blurry nearly all the time. This still reads as a
    // continuous, eased pan while leaving real settled time each cycle for
    // tiles to render sharp before the next ping moves it again.
    final ctrl = _navAnimCtrl ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..addListener(_onNavAnimTick);
    ctrl.forward(from: 0);
  }

  void _onNavAnimTick() {
    if (!mounted) return;
    final fromC = _navFromCenter;
    final toC = _navToCenter;
    final ctrl = _navAnimCtrl;
    if (fromC == null || toC == null || ctrl == null) return;
    final t = Curves.easeOutCubic.transform(ctrl.value);
    final lat = fromC.latitude + (toC.latitude - fromC.latitude) * t;
    final lng = fromC.longitude + (toC.longitude - fromC.longitude) * t;
    final zoom = _navFromZoom + (_navToZoom - _navFromZoom) * t;
    final rotation =
        _navFromRotation + (_navToRotation - _navFromRotation) * t;
    _controller.moveAndRotate(LatLng(lat, lng), zoom, rotation);
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
    if (!force &&
        _lastFitPoints != null &&
        listEquals(points, _lastFitPoints)) {
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
    if (_awayFromRoute) setState(() => _awayFromRoute = false);
  }

  /// Shared camera tween used by both driver-follow ([_animateTo]) and
  /// fit-to-pins ([_maybeFitPins]) — only the destination differs.
  void _animateCamera({
    required LatLng toCenter,
    required double toZoom,
    double? toRotation,
    required void Function(AnimationController?) controllerSlot,
    Duration duration = const Duration(milliseconds: 600),
    Curve curve = Curves.easeOutCubic,
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
    final curved = CurvedAnimation(parent: anim, curve: curve);
    curved.addListener(() {
      if (!mounted) return;
      final t = curved.value;
      final lat =
          fromCenter.latitude + (toCenter.latitude - fromCenter.latitude) * t;
      final lng = fromCenter.longitude +
          (toCenter.longitude - fromCenter.longitude) * t;
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
  ///
  /// [previous] is the route this is replacing, if any. While a trip is
  /// active the route target tracks the driver's live position (see
  /// `TripScreen`'s `liveRouting`), so a fresh route recomputes on every
  /// ~5s GPS ping — same destination-ward end, just trimmed from the front
  /// as the vehicle advances. Replaying the full growth animation on every
  /// one of those made the route look like it was constantly re-rendering
  /// itself rather than the road simply disappearing behind the vehicle, so
  /// that case snaps the polyline straight to the new geometry instead;
  /// only a genuinely new route (first arrival, or the destination-ward end
  /// itself changing — e.g. switching from routing-to-pickup to
  /// routing-to-destination) gets the growth reveal.
  void _animateRouteReveal(List<LatLng> target, List<LatLng>? previous) {
    _routeAnim?.dispose();
    if (target.length < 2) {
      setState(() => _revealedRoute = target);
      return;
    }
    if (previous != null &&
        previous.isNotEmpty &&
        _closeEnough(previous.last, target.last)) {
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

  bool _closeEnough(LatLng a, LatLng b) {
    const dist = Distance();
    return dist.as(LengthUnit.Meter, a, b) < 30;
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

  /// The map's real box can be transiently smaller than its final size —
  /// most commonly right as this screen regains focus while a keyboard
  /// (from an address-search screen just popped) is still animating closed,
  /// shrinking the available body height for a few frames. If a pin-fit
  /// happens to run during that window it computes a valid but far-too-
  /// zoomed-out camera (plenty of finite headroom, so the earlier NaN/
  /// Infinite guards don't catch it), and since it's only re-triggered by
  /// the *pins* changing, nothing ever corrects it afterwards. flutter_map
  /// fires this event on every genuine resize, so re-fitting here (once the
  /// resize settles) self-heals the moment the layout reaches its true
  /// final size — debounced since a resize animation emits many events in
  /// quick succession.
  void _onMapEvent(MapEvent event) {
    if (event is MapEventNonRotatedSizeChange) {
      if (widget.autoFitPins) {
        _resizeFitDebounce?.cancel();
        _resizeFitDebounce = Timer(const Duration(milliseconds: 200), () {
          if (mounted) _maybeFitPins(force: true);
        });
      }
      // Same self-heal, for the other camera-driving mode: a fullscreen nav
      // route push (see NavigationScreen) can report a resize mid-transition
      // before the page reaches its final size, and `initState`'s one-shot
      // `moveAndRotate` — which only runs once, before this widget has any
      // resize event to react to — has no chance to redo itself against the
      // corrected size. Without this, the map is stuck at whatever (possibly
      // near-zero-height) box it first measured, rendering only a sliver of
      // tiles and leaving the rest of the screen blank.
      final target = widget.navigationTarget;
      if (target != null) {
        _resizeNavDebounce?.cancel();
        _resizeNavDebounce = Timer(const Duration(milliseconds: 200), () {
          if (mounted) _animateTo(target);
        });
      }
    }
    if (widget.showRecenterButton) _updateAwayFromRoute();
  }

  /// Recomputes [_awayFromRoute]. Two different "what am I away from"
  /// definitions depending on which camera mode is active:
  ///
  /// - Following a live [navigationTarget] (turn-by-turn, driver or rider
  ///   watching the driver move): "away" is a plain fixed-radius check
  ///   against that target's current point — the thing being followed is
  ///   one point, not a span, so there's no route/bounds size to scale
  ///   against.
  /// - Fitted to [autoFitPins] pins instead: drifted from the fitted route's
  ///   own center, relative to the route's own span — a fixed-meter
  ///   threshold would be too tight for a long cross-town route and too
  ///   loose for two pins a block apart.
  void _updateAwayFromRoute() {
    const dist = Distance();
    final target = widget.navigationTarget;
    if (target != null) {
      final offset =
          dist.as(LengthUnit.Meter, target.point, _controller.camera.center);
      // The camera itself now intentionally sits ~[_lookAheadMeters] away
      // from the raw target point (see `_lookAheadCenter`), so that offset
      // alone must not read as the viewer having panned away.
      final away = offset > 80 + _lookAheadMeters;
      if (away != _awayFromRoute && mounted) {
        setState(() => _awayFromRoute = away);
      }
      return;
    }
    final points = _lastFitPoints;
    if (points == null || points.length < 2) return;
    final bounds = LatLngBounds.fromPoints(points);
    final halfDiagonal =
        dist.as(LengthUnit.Meter, bounds.southWest, bounds.northEast) / 2;
    final offset =
        dist.as(LengthUnit.Meter, bounds.center, _controller.camera.center);
    final away = offset > halfDiagonal * 1.3 + 150;
    if (away != _awayFromRoute && mounted) {
      setState(() => _awayFromRoute = away);
    }
  }

  @override
  void dispose() {
    _navAnimCtrl?.dispose();
    _fitAnim?.dispose();
    _routeAnim?.dispose();
    _resizeFitDebounce?.cancel();
    _resizeNavDebounce?.cancel();
    for (final anim in _pinAnims.values) {
      anim.dispose();
    }
    super.dispose();
  }

  /// Builds one marker, keyed by the pin's stable identity so its pop-in
  /// animation ([_PopInMarker]) plays once when the pin first appears and
  /// never replays on an unrelated rebuild (a fare tick, a route refresh).
  Marker _markerFor(MapPin pin, int index) {
    return Marker(
      key: ValueKey(pin.id ?? 'pin-$index'),
      point: pin.id != null ? (_pinDisplay[pin.id!] ?? pin.point) : pin.point,
      width: 44,
      height: 44,
      alignment: Alignment.topCenter,
      rotate: pin.rotate,
      child: _PopInMarker(
        child: pin.label != null
            ? _NumberedPin(label: pin.label!, color: pin.color)
            : pin.heading != null
                ? Transform.rotate(
                    angle: pin.heading! * (pi / 180),
                    child: Icon(pin.icon, color: pin.color, size: 38),
                  )
                : Icon(pin.icon, color: pin.color, size: 38),
      ),
    );
  }

  /// An "arrive at HH:MM" pill floating above [callout.point] — wide enough
  /// for the text, so unlike the fixed-size pin markers this sizes itself
  /// and centers on its point rather than pointing up from below it.
  Marker _calloutMarker(MapCallout callout) {
    return Marker(
      key: ValueKey(
          'callout-${callout.point.latitude}-${callout.point.longitude}'),
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
        // Positioned.fill, not a bare Stack child — belt-and-braces so this
        // Stack's own sizing is never in question regardless of `fit`.
        Positioned.fill(
          child: FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: widget.center,
              initialZoom: widget.zoom,
              onTap: widget.onTap == null ? null : (_, p) => widget.onTap!(p),
              onMapEvent: _onMapEvent,
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
                tileProvider: _tileProvider,
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
                    Polyline(
                      points: _revealedRoute,
                      strokeWidth: 5,
                      color: routeLineColor,
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
        if (widget.showRecenterButton &&
            (widget.navigationTarget == null || _awayFromRoute))
          // Bottom-right (same spot showLocateButton would use — the two are
          // never both on for the same screen). Two different jobs depending
          // on camera mode:
          //
          // - Following a live [navigationTarget] (turn-by-turn): a plain
          //   "my location" button doesn't make sense here — the camera is
          //   already auto-following the *driver's* position, not the
          //   viewer's own GPS, and the next position update would just
          //   override it anyway. So this only appears once the viewer has
          //   panned away, and snaps straight back to the live target.
          // - Otherwise (fitted to [autoFitPins] pins): defaults to centering
          //   on the viewer's own GPS, and swaps to "back to route" once
          //   they've panned far enough from the fitted route.
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
                  tooltip: widget.navigationTarget != null
                      ? 'Recenter'
                      : (_awayFromRoute ? 'Back to route' : 'My location'),
                  onPressed: widget.navigationTarget != null
                      ? () => _animateTo(widget.navigationTarget!)
                      : (_awayFromRoute
                          ? () => _maybeFitPins(force: true)
                          : _locateMe),
                  icon: _locating
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        )
                      : Icon(widget.navigationTarget != null
                          ? Icons.near_me_rounded
                          : (_awayFromRoute
                              ? Icons.route_rounded
                              : Icons.my_location_rounded)),
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
              BoxShadow(
                  color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
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
