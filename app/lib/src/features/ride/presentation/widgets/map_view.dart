import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/location.dart';
import '../../application/trip_ws.dart' show DriverPosition;

/// A pin to render on the map.
class MapPin {
  const MapPin(this.point, this.icon, this.color, {this.rotate = false});
  final LatLng point;
  final IconData icon;
  final Color color;

  /// Keep this pin screen-fixed (pointing "up") regardless of map rotation —
  /// for a directional icon (the driver's nav arrow) on a heading-up map.
  /// Plain location pins (pickup/destination) leave this false so they
  /// rotate with the map like everything else.
  final bool rotate;
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
  });

  final LatLng center;
  final double zoom;
  final List<MapPin> pins;
  final List<LatLng> route;
  final List<MapCircle> circles;
  final void Function(LatLng)? onTap;
  final MapController? controller;

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

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with SingleTickerProviderStateMixin {
  static const _osmFallback = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  late final MapController _controller = widget.controller ?? MapController();
  bool _locating = false;

  AnimationController? _navAnim;

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
    }
  }

  @override
  void didUpdateWidget(covariant MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.navigationTarget;
    if (target == null) return;
    final prev = oldWidget.navigationTarget;
    if (prev == null ||
        prev.point != target.point ||
        prev.heading != target.heading) {
      _animateTo(target);
    }
  }

  /// flutter_map's `rotation` is how much the map content itself is turned;
  /// to make a compass [heading] point "up" on screen, the content has to
  /// turn the opposite way. (Sign flipped here rather than in the caller —
  /// easy single-line fix if it ever reads backwards on a real device.)
  double? _mapRotationFor(double? heading) => heading == null ? null : -heading;

  void _animateTo(DriverPosition target) {
    final camera = _controller.camera;
    final fromCenter = camera.center;
    final fromZoom = camera.zoom;
    final fromRotation = camera.rotation;
    final toRotationRaw = _mapRotationFor(target.heading) ?? fromRotation;
    // Shortest angular path — don't spin 350° the long way round for what's
    // really a 10° turn.
    var delta = (toRotationRaw - fromRotation) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    final toRotation = fromRotation + delta;

    _navAnim?.dispose();
    final anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
    curved.addListener(() {
      if (!mounted) return;
      final t = curved.value;
      final lat = fromCenter.latitude +
          (target.point.latitude - fromCenter.latitude) * t;
      final lng = fromCenter.longitude +
          (target.point.longitude - fromCenter.longitude) * t;
      final zoom = fromZoom + (widget.navigationZoom - fromZoom) * t;
      final rotation = fromRotation + (toRotation - fromRotation) * t;
      _controller.moveAndRotate(LatLng(lat, lng), zoom, rotation);
    });
    _navAnim = anim;
    anim.forward();
  }

  @override
  void dispose() {
    _navAnim?.dispose();
    super.dispose();
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
            if (widget.route.length >= 2)
              PolylineLayer(
                polylines: [
                  // Blue route line — the brand saffron collides with OSM road/POI colors.
                  Polyline(
                    points: widget.route,
                    strokeWidth: 5,
                    color: const Color(0xFF1A73E8),
                    borderStrokeWidth: 1.5,
                    borderColor: Colors.white,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                for (final pin in widget.pins)
                  Marker(
                    point: pin.point,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    rotate: pin.rotate,
                    child: Icon(pin.icon, color: pin.color, size: 38),
                  ),
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
      ],
    );
  }
}
