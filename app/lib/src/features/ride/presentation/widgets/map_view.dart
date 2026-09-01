import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as mgl;

import '../../../../core/config/app_config.dart';
import '../../../../core/location.dart';

/// The route line's own blue — the brand saffron collides with OSM road/POI
/// colors on the tile layer. Pickup/destination pins share it too, so a
/// trip's whole path (pins + line) reads as one consistent visual, not
/// mismatched brand-color pins against a blue line.
const routeLineColor = Color(0xFF1A73E8);

mgl.LatLng _toMgl(LatLng p) => mgl.LatLng(p.latitude, p.longitude);
LatLng _fromMgl(mgl.LatLng p) => LatLng(p.latitude, p.longitude);

/// A pin to render on the map.
class MapPin {
  const MapPin(this.point, this.icon, this.color, {this.heading, this.id, this.label});
  final LatLng point;
  final IconData icon;
  final Color color;

  /// Bearing (degrees, 0-360) to rotate this pin's icon by — for a
  /// directional icon (the driver's nav arrow) so it visibly turns in place
  /// to face the reported heading.
  final double? heading;

  /// Stable identity ("pickup", "stop-0", "dest", …) used to key the marker
  /// so its entrance animation plays once per pin, not on every map
  /// rebuild — a route recalculation or fare tick shouldn't replay the pop-in
  /// for pins that were already there, and so it glides to a new position
  /// instead of snapping. Pins with no id fall back to list position for
  /// identity and always snap.
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

/// Replaces flutter_map's `MapController` as [MapView]'s public controller
/// type — constructed synchronously by a caller the same way
/// (`final _c = MapViewController();`), but the real native controller
/// (`MapLibreMapController`) only exists once the platform view has actually
/// been created, so calls made before then are simply dropped (matches the
/// old controller's own behavior of being a no-op before the map exists;
/// nothing here is ever called that early in practice — callers only move
/// the map in response to a user action, well after first paint).
class MapViewController {
  mgl.MapLibreMapController? _native;

  void _attach(mgl.MapLibreMapController controller) => _native = controller;

  void move(LatLng point, double zoom) {
    _native?.moveCamera(mgl.CameraUpdate.newLatLngZoom(_toMgl(point), zoom));
  }
}

/// Reusable OSM map (self-hosted vector tiles via Martin — see
/// `AppConfig.martinBaseUrl`). Optional tap callback for picking a point,
/// and a pin list for pickup/destination/driver.
///
/// Backed by `maplibre_gl` (native MapLibre GL, replacing the earlier
/// flutter_map/raster-tile implementation) — markers are native `Symbol`
/// annotations rather than Flutter widgets, since MapLibre has no way to
/// place an arbitrary widget on the map: plain icon pins are pre-rendered
/// PNG assets (`assets/map_icons/`) tinted at runtime via a `dart:ui`
/// `ColorFilter` (see [_MarkerImages.iconBytes]); numbered badges and ETA
/// callouts are drawn directly onto a `Canvas` instead (see
/// [_MarkerImages.badgeBytes]/[_MarkerImages.calloutBytes]) since their
/// content — a number, a time string — varies per instance.
///
/// Map rotation/heading-up "fullscreen navigation" mode was dropped in this
/// migration (see the app's own note on retiring the dedicated nav screen in
/// favor of showing live navigation on the trip screen instead) — this map
/// is always north-up. A directional pin (the driver's nav arrow) still
/// rotates in place via [MapPin.heading] → `SymbolOptions.iconRotate`.
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
    this.autoFitPins = false,
    this.fitPadding = const EdgeInsets.fromLTRB(48, 96, 48, 320),
    this.showRecenterButton = false,
    this.callouts = const [],
    this.enableDoubleTapZoom = true,
  });

  final LatLng center;
  final double zoom;
  final List<MapPin> pins;
  final List<LatLng> route;
  final List<MapCircle> circles;
  final void Function(LatLng)? onTap;
  final MapViewController? controller;

  /// Floating "arrive at HH:MM"-style labels anchored above a point.
  final List<MapCallout> callouts;

  /// Shows a floating "recenter on my location" button, bottom-right — off
  /// by default so screens that already manage their own map overlays there
  /// (or don't want one, e.g. a small preview map) aren't affected.
  /// Bottom (not top) so it's reachable one-handed, thumb-distance from
  /// wherever the hand is already holding the phone.
  final bool showLocateButton;

  /// `false` for a screen that wraps this map in its own double-tap
  /// gesture (e.g. the in-trip map's double-tap-to-expand-the-status-sheet
  /// toggle) — MapLibre's own double-tap-to-zoom would otherwise compete
  /// with that gesture. Pinch-zoom stays available either way; this only
  /// drops the double-tap shortcut for it.
  final bool enableDoubleTapZoom;

  /// Extra space to leave above the bottom edge, e.g. to clear a bottom
  /// sheet's collapsed height so the button isn't sitting under it.
  final double locateButtonBottomOffset;

  /// When true, the camera smoothly zooms/pans to keep every pin in
  /// [pins] visible whenever their positions change (2+ pins) — the
  /// "route planning" camera behavior for pickup/stops/destination.
  final bool autoFitPins;

  /// Screen-space padding kept clear around the fitted pins — the larger
  /// bottom value leaves room for a booking sheet sitting over the map.
  final EdgeInsets fitPadding;

  /// Shows a single floating nav button, bottom-right (same slot
  /// [showLocateButton] would use — don't set both on the same screen):
  /// centers on the rider's live GPS by default, and swaps to "back to
  /// route" once they've panned/zoomed far enough from the fitted route
  /// that the route is the more useful target. Meaningful alongside
  /// [autoFitPins]/2+ [pins]; harmless without it — the button just always
  /// acts as "my location".
  final bool showRecenterButton;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with TickerProviderStateMixin {
  mgl.MapLibreMapController? _controller;
  final _mapBoxKey = GlobalKey();
  bool _styleReady = false;
  bool _locating = false;
  bool _disposed = false;

  final _images = _MarkerImages();

  // `didUpdateWidget` fires `_syncPins`/`_syncCallouts`/`_syncCircles`/
  // `_drawRoute` as fire-and-forget async calls on every rebuild, and none
  // of the three symbol/circle maps below have any cancellation. On a live
  // screen (GPS pings, `SearchRadar`'s ~60fps ring updates) that widget can
  // rebuild again before the previous call's platform-channel round-trips
  // finish, so two overlapping calls race on the same map: one removes a
  // symbol/circle while the other, working off a now-stale reference,
  // updates it — which crashed for real with maplibre_gl's own
  // `AnnotationManager.set` assertion ("you can only set existing
  // annotations"). `_exclusive` below serializes each op by tag instead.
  final Set<String> _syncInFlight = {};
  final Set<String> _syncPending = {};

  Future<void> _exclusive(String tag, Future<void> Function() task) async {
    if (_syncInFlight.contains(tag)) {
      _syncPending.add(tag);
      return;
    }
    _syncInFlight.add(tag);
    try {
      await task();
    } finally {
      _syncInFlight.remove(tag);
    }
    if (_syncPending.remove(tag) && !_disposed) {
      await _exclusive(tag, task);
    }
  }

  final Map<String, mgl.Symbol> _pinSymbols = {};
  final Map<String, LatLng> _pinDisplay = {};
  final Map<String, AnimationController> _pinMoveAnims = {};
  final Map<String, AnimationController> _pinPopAnims = {};

  final Map<String, mgl.Symbol> _calloutSymbols = {};

  mgl.Line? _routeLine;
  AnimationController? _routeAnim;
  List<LatLng> _revealedRoute = const [];
  List<LatLng>? _lastRoute;

  final List<mgl.Circle> _circlePool = [];

  List<LatLng>? _lastFitPoints;
  bool _awayFromRoute = false;

  /// How long a moving pin (the live driver marker) takes to glide from its
  /// last displayed position to a newly-arrived one — a touch under the
  /// ~5s GPS ping cadence so it settles before the next ping lands, instead
  /// of perpetually chasing a moving target.
  static const _pinMoveDuration = Duration(milliseconds: 4200);

  static const _distance = Distance();

  /// A newly-reported point further than this from where a pin was last
  /// displayed is treated as "this screen was away for a while" (covered by
  /// another route, backgrounded, etc.) rather than a normal single GPS
  /// ping's worth of movement — animating that whole accumulated gap at the
  /// usual glide speed would look like the vehicle slowly crawling to catch
  /// up over several seconds instead of just being where it actually is.
  static const _bigJumpMeters = 150.0;

  @override
  void initState() {
    super.initState();
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
    if (_disposed || !_styleReady) return;
    _syncGuarded('pins', () => _syncPins(widget.pins));
    _syncGuarded('callouts', () => _syncCallouts(widget.callouts));
    _syncGuarded('circles', () => _syncCircles(widget.circles));
    if (!listEquals(widget.route, _lastRoute)) {
      final prevRoute = _lastRoute;
      _lastRoute = widget.route;
      _animateRouteReveal(widget.route, prevRoute);
    }
    if (widget.autoFitPins) _maybeFitPins();
  }

  /// Runs an [_exclusive] sync call with recovery for both known
  /// maplibre_gl races that can surface here (see the two error checks
  /// below for what each one is and how it's confirmed to happen):
  ///
  /// - "annotation manager ... has not been initialized": [_onStyleLoaded]
  ///   already retries this for the very first sync call it makes, but a
  ///   `didUpdateWidget` call (e.g. the driver's very first live position
  ///   arriving) can just as easily land inside that same brief startup
  ///   window — and unlike the first call, had nothing retrying *it*, so
  ///   that update was silently dropped for good (reported live: the
  ///   driver marker missing right after a cold start, until some later,
  ///   unrelated update happened to land after the race window closed and
  ///   finally drew it). Retried the same bounded way here too.
  /// - "you can only set existing annotations": see
  ///   [_isStaleAnnotationError]'s own doc.
  void _syncGuarded(String tag, Future<void> Function() task, {int attempt = 0}) {
    _exclusive(tag, task).catchError((Object error, StackTrace st) async {
      if (_disposed) return;
      if (_isStaleAnnotationError(error)) {
        _clearAnnotationCaches();
        await _fullResync(force: true);
        return;
      }
      if (_isNotInitializedError(error) && attempt < 3) {
        await Future.delayed(Duration(milliseconds: 150 * (attempt + 1)));
        if (!_disposed) _syncGuarded(tag, task, attempt: attempt + 1);
        return;
      }
      throw error;
    });
  }

  static bool _isNotInitializedError(Object error) =>
      error is Exception && error.toString().contains('has not been initialized');

  /// True for maplibre_gl's `AnnotationManager.set` assertion — thrown when
  /// this widget's own symbol/line/circle caches (`_pinSymbols` etc.) still
  /// reference native annotations that no longer exist. Confirmed live: this
  /// happens when the underlying native map view is torn down and recreated
  /// by the OS mid-trip (backgrounding + the screen locking, then resuming,
  /// was enough to trigger it) without this `State` — and its caches —
  /// being recreated in step. Once triggered it repeats forever on every
  /// subsequent update (each one hits the same stale reference), so the
  /// driver's own marker in particular never recovers on its own without
  /// the recovery in [_syncGuarded] — distinct from the concurrent-call
  /// race [_exclusive] already guards against, which this doesn't replace.
  /// A native reset invalidates *every* annotation, not just whichever one
  /// happened to fail first, so recovery (in [_syncGuarded]) drops every
  /// local cache and does a full from-scratch resync (the same one
  /// [_onStyleLoaded] already runs for its own first-load race) rather than
  /// patching just the one caller that happened to throw.
  static bool _isStaleAnnotationError(Object error) =>
      error is AssertionError &&
      error.toString().contains('you can only set existing annotations');

  void _clearAnnotationCaches() {
    _pinSymbols.clear();
    _pinDisplay.clear();
    for (final anim in _pinMoveAnims.values) {
      anim.dispose();
    }
    _pinMoveAnims.clear();
    for (final anim in _pinPopAnims.values) {
      anim.dispose();
    }
    _pinPopAnims.clear();
    _calloutSymbols.clear();
    _routeLine = null;
    _lastRoute = null;
    _circlePool.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _routeAnim?.dispose();
    for (final anim in _pinMoveAnims.values) {
      anim.dispose();
    }
    for (final anim in _pinPopAnims.values) {
      anim.dispose();
    }
    super.dispose();
  }

  Future<void> _onMapCreated(mgl.MapLibreMapController controller) async {
    _controller = controller;
    widget.controller?._attach(controller);
  }

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    await _fullResync(force: true);
  }

  /// Draws pins/callouts/circles/route from scratch and re-fits the camera
  /// — everything a freshly-loaded style (or a from-scratch recovery after
  /// [_recoverFromStaleAnnotations] clears the caches) needs.
  ///
  /// maplibre_gl's controller only fires `onStyleLoadedCallback` once its
  /// annotation managers report `isInitialized`, but on a real device the
  /// very first load has still thrown "annotation manager ... has not been
  /// initialized" out of the very first `addSymbol` call here — confirmed
  /// live: a screen with static pins that never triggers another
  /// `didUpdateWidget` rebuild was left with a start-to-finish blank map, no
  /// pins/route/callouts ever drawn. Retrying absorbs that one-time race
  /// (plugin-internal, not something this app controls) instead of silently
  /// losing the whole draw.
  Future<void> _fullResync({bool force = false}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _exclusive('pins', () => _syncPins(widget.pins));
        await _exclusive('callouts', () => _syncCallouts(widget.callouts));
        await _exclusive('circles', () => _syncCircles(widget.circles));
        if (widget.route.length >= 2) {
          _revealedRoute = widget.route;
          await _exclusive('route', () => _drawRoute(_revealedRoute));
        }
        break;
      } catch (_) {
        if (_disposed || attempt == 2) rethrow;
        await Future.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
    if (widget.autoFitPins) _maybeFitPins(force: force);
  }

  // ── Pins ─────────────────────────────────────────────────────────────────

  Future<void> _syncPins(List<MapPin> pins) async {
    final controller = _controller;
    if (controller == null) return;
    final seenKeys = <String>{};
    for (var i = 0; i < pins.length; i++) {
      final pin = pins[i];
      final key = pin.id ?? 'pin-$i';
      seenKeys.add(key);
      final bytes = pin.label != null
          ? await _images.badgeBytes(pin.label!, pin.color)
          : await _images.iconBytes(pin.icon, pin.color);
      final imageName = pin.label != null
          ? 'badge:${pin.label}:${pin.color.toARGB32()}'
          : 'icon:${_iconAssetName(pin.icon)}:${pin.color.toARGB32()}';
      await _images.ensureRegistered(controller, imageName, bytes);

      final targetSize = pin.label != null
          ? _images.badgeAndCalloutDisplaySize
          : _images.iconDisplaySize;
      final existing = _pinSymbols[key];
      final anchorPoint =
          pin.id != null ? (_pinDisplay[pin.id!] ?? pin.point) : pin.point;
      if (existing == null) {
        _pinDisplay[key] = pin.point;
        final symbol = await controller.addSymbol(
          mgl.SymbolOptions(
            geometry: _toMgl(anchorPoint),
            iconImage: imageName,
            iconSize: targetSize * 0.4,
            iconRotate: pin.heading ?? 0,
            iconAnchor: pin.label != null ? 'bottom' : 'center',
          ),
        );
        _pinSymbols[key] = symbol;
        _animatePopIn(key, symbol, targetSize);
      } else {
        await controller.updateSymbol(
          existing,
          mgl.SymbolOptions(
            iconImage: imageName,
            iconRotate: pin.heading ?? 0,
          ),
        );
        if (pin.id != null) {
          final from = _pinDisplay[pin.id!] ?? pin.point;
          if (from != pin.point) {
            if (_distance.as(LengthUnit.Meter, from, pin.point) >
                _bigJumpMeters) {
              _pinMoveAnims.remove(pin.id)?.dispose();
              _pinDisplay[pin.id!] = pin.point;
              await controller.updateSymbol(
                existing,
                mgl.SymbolOptions(geometry: _toMgl(pin.point)),
              );
            } else {
              _animatePinMove(pin.id!, existing, from, pin.point);
            }
          }
        }
      }
    }
    // Pins no longer present get removed, and their remembered state
    // dropped — if the same id ever reappears later it starts fresh
    // instead of gliding in from a stale, unrelated spot.
    for (final key in _pinSymbols.keys.toList()) {
      if (!seenKeys.contains(key)) {
        final symbol = _pinSymbols.remove(key)!;
        await controller.removeSymbol(symbol);
        _pinDisplay.remove(key);
        _pinMoveAnims.remove(key)?.dispose();
        _pinPopAnims.remove(key)?.dispose();
      }
    }
  }

  void _animatePinMove(String id, mgl.Symbol symbol, LatLng from, LatLng to) {
    _pinMoveAnims.remove(id)?.dispose();
    final controller = _controller;
    if (controller == null) return;
    final anim = AnimationController(vsync: this, duration: _pinMoveDuration);
    // Linear, not eased — a vehicle moves at roughly constant speed between
    // two GPS fixes; an ease-in/out here would read as slowing down to stop
    // at every single ping, which isn't what's happening.
    anim.addListener(() {
      if (_disposed) return;
      final t = anim.value;
      final point = LatLng(
        from.latitude + (to.latitude - from.latitude) * t,
        from.longitude + (to.longitude - from.longitude) * t,
      );
      _pinDisplay[id] = point;
      controller.updateSymbol(symbol, mgl.SymbolOptions(geometry: _toMgl(point)));
    });
    _pinMoveAnims[id] = anim;
    anim.forward();
  }

  void _animatePopIn(String key, mgl.Symbol symbol, double targetSize) {
    final controller = _controller;
    if (controller == null) return;
    final startSize = targetSize * 0.4;
    final anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    final curved = CurvedAnimation(parent: anim, curve: Curves.elasticOut);
    curved.addListener(() {
      if (_disposed) return;
      final size = startSize + (targetSize - startSize) * curved.value;
      controller.updateSymbol(symbol, mgl.SymbolOptions(iconSize: size));
    });
    _pinPopAnims[key] = anim;
    anim.forward();
  }

  // ── Callouts ─────────────────────────────────────────────────────────────

  Future<void> _syncCallouts(List<MapCallout> callouts) async {
    final controller = _controller;
    if (controller == null) return;
    final seenKeys = <String>{};
    for (final callout in callouts) {
      final key =
          'callout:${callout.point.latitude}:${callout.point.longitude}';
      seenKeys.add(key);
      final imageName = 'callout:${callout.text}';
      final bytes = await _images.calloutBytes(callout.text);
      await _images.ensureRegistered(controller, imageName, bytes);
      final existing = _calloutSymbols[key];
      if (existing == null) {
        _calloutSymbols[key] = await controller.addSymbol(
          mgl.SymbolOptions(
            geometry: _toMgl(callout.point),
            iconImage: imageName,
            iconSize: _images.badgeAndCalloutDisplaySize,
            iconAnchor: 'bottom',
            iconOffset: const Offset(0, -34),
          ),
        );
      } else {
        await controller.updateSymbol(
          existing,
          mgl.SymbolOptions(iconImage: imageName),
        );
      }
    }
    for (final key in _calloutSymbols.keys.toList()) {
      if (!seenKeys.contains(key)) {
        await controller.removeSymbol(_calloutSymbols.remove(key)!);
      }
    }
  }

  // ── Route ────────────────────────────────────────────────────────────────

  /// Draws the route line as a "reveal" — a snake growing from the pickup
  /// end to the destination end — instead of popping in fully formed the
  /// instant a route arrives (straight-line guess, then the real routed
  /// geometry once it lands).
  ///
  /// [previous] is the route this is replacing, if any. While a trip is
  /// active the route target tracks the driver's live position, so a fresh
  /// route recomputes on every ~5s GPS ping — same destination-ward end,
  /// just trimmed from the front as the vehicle advances. Replaying the full
  /// growth animation on every one of those made the route look like it was
  /// constantly re-rendering itself rather than the road simply disappearing
  /// behind the vehicle, so that case snaps the polyline straight to the new
  /// geometry instead; only a genuinely new route (first arrival, or the
  /// destination-ward end itself changing) gets the growth reveal.
  Future<void> _animateRouteReveal(
      List<LatLng> target, List<LatLng>? previous) async {
    _routeAnim?.dispose();
    _routeAnim = null;
    if (target.length < 2) {
      _revealedRoute = target;
      await _exclusive('route', () => _drawRoute(_revealedRoute));
      return;
    }
    if (previous != null &&
        previous.isNotEmpty &&
        _closeEnough(previous.last, target.last)) {
      _revealedRoute = target;
      await _exclusive('route', () => _drawRoute(_revealedRoute));
      return;
    }
    final anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
    curved.addListener(() {
      if (_disposed) return;
      _revealedRoute = _tracePrefix(target, curved.value);
      _exclusive('route', () => _drawRoute(_revealedRoute));
    });
    _routeAnim = anim;
    anim.forward();
  }

  Future<void> _drawRoute(List<LatLng> points) async {
    final controller = _controller;
    if (controller == null) return;
    final geometry = [for (final p in points) _toMgl(p)];
    final line = _routeLine;
    if (points.length < 2) {
      if (line != null) {
        await controller.removeLine(line);
        _routeLine = null;
      }
      return;
    }
    if (line == null) {
      _routeLine = await controller.addLine(
        mgl.LineOptions(
          geometry: geometry,
          lineColor: '#${routeLineColor.toARGB32().toRadixString(16).substring(2)}',
          lineWidth: 5,
        ),
      );
    } else {
      await controller.updateLine(line, mgl.LineOptions(geometry: geometry));
    }
  }

  bool _closeEnough(LatLng a, LatLng b) =>
      _distance.as(LengthUnit.Meter, a, b) < 30;

  /// The leading portion of [points] covering fraction [t] of the total
  /// line length (0 = nothing drawn, 1 = the whole route) — a straight index
  /// cutoff would make the reveal speed uneven across long/short segments,
  /// so this walks by cumulative distance instead.
  List<LatLng> _tracePrefix(List<LatLng> points, double t) {
    if (t >= 1) return points;
    if (t <= 0) return [points.first];
    final segLengths = [
      for (var i = 0; i < points.length - 1; i++)
        _distance.as(LengthUnit.Meter, points[i], points[i + 1]),
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

  // ── Circles ──────────────────────────────────────────────────────────────

  /// `circle-radius` in the native style spec is screen pixels, not meters,
  /// so a geographic radius has to be converted using the current zoom/
  /// latitude (standard Web Mercator ground-resolution formula) — recomputed
  /// whenever the circle list changes and once more after any zoom gesture
  /// settles (`onCameraIdle`), so rings stay the right geographic size as
  /// the map is zoomed rather than a fixed screen size.
  double _metersPerPixel(double lat) {
    final zoom = _controller?.cameraPosition?.zoom ?? widget.zoom;
    return 156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
  }

  Future<void> _syncCircles(List<MapCircle> circles) async {
    final controller = _controller;
    if (controller == null) return;
    // A fixed-size pool, updated by index rather than removed/recreated —
    // `SearchRadar`'s pulsing rings regenerate this list on every animation
    // frame (~60fps), and remove+recreate that often would mean that many
    // platform-channel round-trips a second per ring.
    for (var i = 0; i < circles.length; i++) {
      final c = circles[i];
      final metersPerPixel = _metersPerPixel(c.center.latitude);
      final pixelRadius = metersPerPixel > 0
          ? c.radiusMeters / metersPerPixel
          : c.radiusMeters;
      final options = mgl.CircleOptions(
        geometry: _toMgl(c.center),
        circleRadius: pixelRadius,
        circleColor: _hex(c.color),
        circleOpacity: c.color.a,
        circleStrokeColor: _hex(c.borderColor),
        circleStrokeWidth: c.borderStrokeWidth,
        circleStrokeOpacity: c.borderColor.a,
      );
      if (i < _circlePool.length) {
        await controller.updateCircle(_circlePool[i], options);
      } else {
        _circlePool.add(await controller.addCircle(options));
      }
    }
    while (_circlePool.length > circles.length) {
      await controller.removeCircle(_circlePool.removeLast());
    }
  }

  void _refreshCircleRadii() {
    if (widget.circles.isEmpty) return;
    _exclusive('circles', () => _syncCircles(widget.circles));
  }

  // ── Camera ───────────────────────────────────────────────────────────────

  /// The set of points the camera should keep visible — every current pin's
  /// position, plus the route polyline itself. `null`/empty when there's
  /// nothing worth fitting to yet.
  ///
  /// The route matters, not just its two endpoints: a driver/pickup pair
  /// fit from pins alone routinely left the actual road — which bows out
  /// far from the straight line between them, as any real street network
  /// does — running off the edge of the screen, forcing a manual pinch-
  /// zoom to see the whole planned route (reported live; Yango/Pathao both
  /// keep the full route in frame instead).
  ///
  /// Drops exact (0, 0) — "Null Island" is never a legitimate pickup/stop/
  /// destination for this app, only ever a sign an upstream point hasn't
  /// resolved yet; including it would blow the fit bounds out to a
  /// whole-world view instead of just waiting for the real coordinate.
  List<LatLng>? _fittablePoints() {
    final points = [
      for (final p in widget.pins)
        if (p.point.latitude != 0 || p.point.longitude != 0) p.point,
      for (final p in widget.route)
        if (p.latitude != 0 || p.longitude != 0) p,
    ];
    return points.length < 2 ? null : points;
  }

  /// Smoothly zooms/pans to fit every pin on screen, re-fitting only when the
  /// actual point set changed (not on every unrelated rebuild) — unless
  /// [force], which the recenter button uses to snap back even when nothing
  /// about the pins themselves has changed (the rider just panned away).
  ///
  /// Deferred a frame: this reads `_mapBoxKey.currentContext?.size`, and
  /// callers include `didUpdateWidget`, which runs mid-build — reading a
  /// RenderBox's size before it's laid out for that frame is illegal and
  /// crashed the app for real (`_dependents.isEmpty` assertion) instead of
  /// just throwing a clean error. `addPostFrameCallback` waits until layout
  /// has settled.
  void _maybeFitPins({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _doFitPins(force: force);
    });
  }

  void _doFitPins({bool force = false}) {
    final controller = _controller;
    if (controller == null) return;
    final points = _fittablePoints();
    if (points == null) return;
    if (!force && _lastFitPoints != null && listEquals(points, _lastFitPoints)) {
      return;
    }
    _lastFitPoints = points;

    var minLat = points.first.latitude, maxLat = points.first.latitude;
    var minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    // Computed by hand rather than trusting `CameraUpdate.newLatLngBounds`'s
    // own padding — that consistently landed much further zoomed out than
    // intended on a real device (confirmed live), and this way the zoom
    // level is fully our own math to reason about/tune rather than an
    // opaque native padding-unit interpretation.
    final mapSize = _mapBoxKey.currentContext?.size ?? MediaQuery.of(context).size;
    final zoom = _boundsZoom(
      sw: LatLng(minLat, minLng),
      ne: LatLng(maxLat, maxLng),
      mapSize: mapSize,
      padding: widget.fitPadding,
    );
    // The map is full-bleed (the trip sheet just overlays on top of it, it
    // doesn't shrink the map's own layout), and `newLatLngZoom`'s target
    // always renders at the *whole viewport's* geometric center regardless
    // of padding. So the zoom computed above correctly leaves room for the
    // sheet, but naively centering on the raw bbox midpoint undoes that —
    // half the reserved room sits above the pins instead of below, and
    // real ride-hailing apps see this camera as the map at
    // `widget.fitPadding`'s edge, then landed points behind the sheet
    // instead. Shift the *target* by the padding asymmetry, in the
    // opposite screen direction from where the room was reserved, so the
    // fitted box actually lands centered in the visible portion.
    final target = _shiftForPadding(center, zoom, widget.fitPadding);
    controller.animateCamera(
      mgl.CameraUpdate.newLatLngZoom(_toMgl(target), zoom),
      duration: const Duration(milliseconds: 600),
    );
    if (_awayFromRoute) setState(() => _awayFromRoute = false);
  }

  /// Moves [center] so that, once rendered at [zoom], it lands at the
  /// center of the *padded* (visible) area instead of the full viewport —
  /// see the call site in [_doFitPins] for why that's not the same point
  /// whenever the padding isn't symmetric (the trip sheet reserves far
  /// more room at the bottom than the top bar does).
  LatLng _shiftForPadding(LatLng center, double zoom, EdgeInsets padding) {
    final worldPx = _worldDim * math.pow(2, zoom);
    final offsetXPx = (padding.right - padding.left) / 2;
    final offsetYPx = (padding.bottom - padding.top) / 2;
    final lng = center.longitude + offsetXPx * 360 / worldPx;
    final latRad = _latRad(center.latitude) - offsetYPx * math.pi / worldPx;
    return LatLng(_latFromRad(latRad), lng);
  }

  /// The zoom level that fits [sw]..[ne] within [mapSize] minus [padding] —
  /// the standard Web Mercator "fit bounds" formula (the same one behind
  /// Google Maps JS's `fitBounds`/Mapbox GL JS's `cameraForBounds`), since
  /// `maplibre_gl`'s own `newLatLngBounds` doesn't expose one directly in a
  /// way that matched what this app actually wants (see the call site).
  double _boundsZoom({
    required LatLng sw,
    required LatLng ne,
    required Size mapSize,
    required EdgeInsets padding,
  }) {
    const zoomMax = 20.0;
    double zoomFor(double paneSize, double fraction) {
      if (fraction <= 0 || paneSize <= 0) return zoomMax;
      return math.log(paneSize / _worldDim / fraction) / math.ln2;
    }

    final availWidth =
        math.max(mapSize.width - padding.horizontal, 40.0);
    final availHeight =
        math.max(mapSize.height - padding.vertical, 40.0);
    final latFraction =
        (_latRad(ne.latitude) - _latRad(sw.latitude)) / math.pi;
    var lngDiff = ne.longitude - sw.longitude;
    if (lngDiff < 0) lngDiff += 360;
    final lngFraction = lngDiff / 360;
    final zoom = math.min(
      zoomFor(availHeight, latFraction.abs()),
      zoomFor(availWidth, lngFraction),
    );
    // MapLibre/Mapbox Native's own "zoom" is calibrated to a 512px world
    // tile, not the 256px one this Google-Maps-JS-derived formula assumes
    // (`_worldDim` above) — the same visual scale is one zoom level lower
    // on the 512px convention (512*2^Z == 256*2^(Z+1)). Feeding the
    // 256-basis result straight to `CameraUpdate.newLatLngZoom` therefore
    // renders one level too close; confirmed live, a fit that the 256px
    // math said should comfortably clear its padding was consistently
    // running the route off both the left and right edges of the screen.
    return (zoom - 1.0).clamp(10.0, zoomMax);
  }

  /// Tile-pixel size of the whole world at zoom 0 — the base unit for both
  /// [_boundsZoom]'s pane-size math and [_shiftForPadding]'s pixel-to-degree
  /// conversion, so the two stay in the same units.
  static const _worldDim = 256.0;

  /// Web Mercator's y-coordinate for [latDeg] (radians, halved so a span of
  /// `pi` covers the whole world height at any zoom) — see [_latFromRad],
  /// its inverse.
  static double _latRad(double latDeg) {
    final sinLat = math.sin(latDeg * math.pi / 180);
    final radX2 = math.log((1 + sinLat) / (1 - sinLat)) / 2;
    return radX2.clamp(-math.pi, math.pi) / 2;
  }

  /// Inverse of [_latRad] (the Gudermannian function, `asin∘tanh`) —
  /// recovers a latitude in degrees from a Mercator-y value. `dart:math`
  /// has no `tanh`, hence the manual `exp`-based expansion.
  ///
  /// `_latRad` divides by 2 twice (once folded into `radX2`, once in its
  /// own return), so undoing it needs `tanh(2r)`, not `tanh(r)` — used the
  /// single-division version here first and it round-tripped 28.13°N
  /// down to 14.5°N (confirmed live via logging), a very wrong inverse.
  static double _latFromRad(double r) {
    final e4r = math.exp(4 * r);
    final tanh2r = (e4r - 1) / (e4r + 1);
    return math.asin(tanh2r.clamp(-1.0, 1.0)) * 180 / math.pi;
  }

  Future<void> _locateMe() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final here = await currentLatLng();
      final zoom = _controller?.cameraPosition?.zoom ?? widget.zoom;
      await _controller?.animateCamera(mgl.CameraUpdate.newLatLngZoom(_toMgl(here), zoom));
    } catch (_) {
      // No location available (permission denied, GPS off) — nothing more
      // to do; the button just doesn't move the map this time.
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// Recomputes [_awayFromRoute] — drifted from the fitted pins' own center,
  /// relative to their own span, so a fixed-meter threshold isn't too tight
  /// for a long cross-town route or too loose for two pins a block apart.
  void _updateAwayFromRoute() {
    final controller = _controller;
    final points = _lastFitPoints;
    if (controller == null || points == null || points.length < 2) return;
    var minLat = points.first.latitude, maxLat = points.first.latitude;
    var minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    final sw = LatLng(minLat, minLng);
    final ne = LatLng(maxLat, maxLng);
    final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    final halfDiagonal = _distance.as(LengthUnit.Meter, sw, ne) / 2;
    final cam = controller.cameraPosition;
    if (cam == null) return;
    final offset = _distance.as(LengthUnit.Meter, center, _fromMgl(cam.target));
    final away = offset > halfDiagonal * 1.3 + 150;
    if (away != _awayFromRoute && mounted) {
      setState(() => _awayFromRoute = away);
    }
  }

  void _onCameraIdle() {
    _refreshCircleRadii();
    if (widget.showRecenterButton) _updateAwayFromRoute();
  }

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  @override
  Widget build(BuildContext context) {
    _images.pixelRatio = MediaQuery.of(context).devicePixelRatio;
    return Stack(
      children: [
        Positioned.fill(
          child: KeyedSubtree(
            key: _mapBoxKey,
            child: mgl.MapLibreMap(
              styleString: AppConfig.martinBaseUrl.isEmpty
                  ? mgl.MapLibreStyles.demo
                  : _StyleCache.jsonFor(AppConfig.martinBaseUrl),
              initialCameraPosition: mgl.CameraPosition(
                target: _toMgl(widget.center),
                zoom: widget.zoom,
              ),
              onMapCreated: _onMapCreated,
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraIdle: _onCameraIdle,
              doubleClickZoomEnabled: widget.enableDoubleTapZoom,
              // The plugin's own native compass widget is positioned in raw
              // platform pixels, ignoring Flutter's `SafeArea` — it renders
              // half-clipped under the status bar (reported live) and this
              // screen already has its own Flutter-positioned recenter
              // button, so there's nothing lost in dropping it.
              compassEnabled: false,
              onMapClick: widget.onTap == null
                  ? null
                  : (_, coords) => widget.onTap!(_fromMgl(coords)),
            ),
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
        if (widget.showRecenterButton)
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
                  tooltip: _awayFromRoute ? 'Back to route' : 'My location',
                  onPressed: _awayFromRoute
                      ? () => _maybeFitPins(force: true)
                      : _locateMe,
                  icon: _locating
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        )
                      : Icon(_awayFromRoute
                          ? Icons.route_rounded
                          : Icons.my_location_rounded),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Maps a [MapPin.icon] value to its pre-rendered asset name — see
/// `assets/map_icons/`, generated offline from the real Material Icons font
/// (`scripts/` has no generator checked in; regenerate by rendering the
/// listed codepoints at high resolution as white-on-transparent PNGs if a
/// new icon is ever needed here).
String _iconAssetName(IconData icon) {
  final known = {
    Icons.two_wheeler_rounded: 'two_wheeler_rounded',
    Icons.location_on_rounded: 'location_on_rounded',
    Icons.sports_score_rounded: 'sports_score_rounded',
    Icons.emoji_people_rounded: 'emoji_people_rounded',
    Icons.navigation_rounded: 'navigation_rounded',
    Icons.adjust_rounded: 'adjust_rounded',
  };
  final name = known[icon];
  assert(name != null,
      'No pre-rendered map-icon asset for $icon — add one to assets/map_icons/ and _iconAssetName.');
  return name ?? 'adjust_rounded';
}

/// Registers (and caches) the native images MapLibre `Symbol`s reference.
/// Plain icon pins are a pre-rendered PNG asset tinted per-color via a
/// `dart:ui` `ColorFilter`; numbered badges and callouts have no fixed
/// asset (their content varies per instance — a number, an ETA string) and
/// are instead drawn directly with `Canvas`/`TextPainter`. Either way the
/// result is cached by its exact content key so an identical marker
/// reused across rebuilds is never re-encoded or re-sent over the platform
/// channel twice.
class _MarkerImages {
  double pixelRatio = 2.0;
  final Set<String> _registered = {};
  final Map<String, Uint8List> _iconCache = {};
  final Map<String, Uint8List> _badgeCache = {};
  final Map<String, Uint8List> _calloutCache = {};

  /// Source PNG size for plain icon pins (`assets/map_icons/`) and the
  /// logical (not device) pixel width they should display at — matching
  /// the old flutter_map markers' 44x44 box.
  static const _iconSourcePx = 192.0;
  static const _iconTargetLogicalPx = 44.0;

  /// Badges/callouts are drawn at this multiple of their intended logical
  /// size for crispness (see [badgeBytes]/[calloutBytes]) — their own
  /// canvas dimensions already bake in the target logical size times this
  /// factor, so displaying them correctly only needs undoing the factor
  /// (not a separate logical-px target the way plain icons need).
  static const _overscan = 3.0;

  /// `SymbolOptions.iconSize` scales the source image's *native* pixels
  /// to *physical* screen pixels 1:1 at `iconSize: 1.0` — logical (Flutter)
  /// pixels are physical pixels divided by [pixelRatio], so this has to
  /// multiply by [pixelRatio], not divide by it, to land on a stable
  /// logical size across devices. (Confirmed live: the inverse — dividing
  /// — rendered every marker and the callout text far too small on a real
  /// high-DPI phone.)
  double get iconDisplaySize =>
      _iconTargetLogicalPx * pixelRatio / _iconSourcePx;

  double get badgeAndCalloutDisplaySize => pixelRatio / _overscan;

  Future<void> ensureRegistered(
      mgl.MapLibreMapController controller, String name, Uint8List bytes) async {
    if (_registered.contains(name)) return;
    await controller.addImage(name, bytes);
    _registered.add(name);
  }

  Future<Uint8List> iconBytes(IconData icon, Color color) async {
    final key = '${_iconAssetName(icon)}:${color.toARGB32()}';
    final cached = _iconCache[key];
    if (cached != null) return cached;
    final data = await rootBundle.load('assets/map_icons/${_iconAssetName(icon)}.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
    );
    final picture = recorder.endRecording();
    final tinted = await picture.toImage(image.width, image.height);
    final bytes = (await tinted.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    tinted.dispose();
    _iconCache[key] = bytes;
    return bytes;
  }

  Future<Uint8List> badgeBytes(String label, Color color) async {
    final key = '$label:${color.toARGB32()}';
    final cached = _badgeCache[key];
    if (cached != null) return cached;
    const d = 3.0; // oversample for crispness; iconSize compensates below
    const circleD = 26.0 * d;
    const tailH = 6.0 * d;
    const w = circleD + 6 * d;
    const h = circleD + tailH + 6 * d;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
    const center = Offset(w / 2, circleD / 2 + 3 * d);
    const radius = circleD / 2;
    canvas.drawCircle(center.translate(0, 1 * d), radius,
        Paint()..color = Colors.black26..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(center, radius, Paint()..color = color);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * d,
    );
    final tail = ui.Path()
      ..moveTo(center.dx - 5 * d, center.dy + radius - 2 * d)
      ..lineTo(center.dx + 5 * d, center.dy + radius - 2 * d)
      ..lineTo(center.dx, center.dy + radius + tailH)
      ..close();
    canvas.drawPath(tail, Paint()..color = color);
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 13 * d,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(w.round(), h.round());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    _badgeCache[key] = bytes;
    return bytes;
  }

  Future<Uint8List> calloutBytes(String text) async {
    final cached = _calloutCache[text];
    if (cached != null) return cached;
    const d = 3.0;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 12.5 * d,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = tp.width + 20 * d;
    final h = tp.height + 12 * d;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      const Radius.circular(10 * d),
    );
    canvas.drawRRect(rrect, Paint()..color = Colors.black.withValues(alpha: 0.82));
    tp.paint(canvas, Offset((w - tp.width) / 2, (h - tp.height) / 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(w.round(), h.round());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    _calloutCache[text] = bytes;
    return bytes;
  }
}

/// Builds (and caches, keyed by Martin base URL) the full style JSON string
/// from the bundled layer-only style asset — see `assets/map_style/style.json`
/// and its generation note in `backend/deploy/martin/style.json`'s own
/// comment. Loaded once synchronously via a pre-warmed cache since
/// `MapLibreMap.styleString` isn't itself async-aware.
class _StyleCache {
  static final Map<String, String> _cache = {};
  static String? _rawLayers;

  /// Call once at app start (before any `MapView` builds) to avoid the
  /// first map's style flashing in a beat late. Safe to skip — `jsonFor`
  /// falls back to the demo style until the real one is ready either way.
  static Future<void> warm() async {
    _rawLayers ??= await rootBundle.loadString('assets/map_style/style.json');
  }

  static String jsonFor(String martinBaseUrl) {
    final cached = _cache[martinBaseUrl];
    if (cached != null) return cached;
    final raw = _rawLayers;
    if (raw == null) {
      // Not warmed yet — kick off the load for next time and fall back to
      // the demo style for this build.
      warm();
      return mgl.MapLibreStyles.demo;
    }
    final style = jsonDecode(raw) as Map<String, dynamic>;
    style['sources'] = {
      'openmaptiles': {
        'type': 'vector',
        'tiles': ['$martinBaseUrl/nepal/{z}/{x}/{y}'],
        'minzoom': 0,
        'maxzoom': 14,
      },
    };
    style['glyphs'] = '$martinBaseUrl/font/{fontstack}/{range}';
    final encoded = jsonEncode(style);
    _cache[martinBaseUrl] = encoded;
    return encoded;
  }
}
