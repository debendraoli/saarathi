import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/config/app_config.dart';

/// A pin to render on the map.
class MapPin {
  const MapPin(this.point, this.icon, this.color);
  final LatLng point;
  final IconData icon;
  final Color color;
}

/// Reusable OSM map (self-hosted tiles in prod; public OSM in dev). Optional tap
/// callback for picking a point, and a pin list for pickup/destination/driver.
class MapView extends StatelessWidget {
  const MapView({
    super.key,
    required this.center,
    this.zoom = 14,
    this.pins = const [],
    this.route = const [],
    this.onTap,
    this.controller,
  });

  final LatLng center;
  final double zoom;
  final List<MapPin> pins;
  final List<LatLng> route;
  final void Function(LatLng)? onTap;
  final MapController? controller;

  static const _osmFallback = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  @override
  Widget build(BuildContext context) {
    final tileUrl = AppConfig.tileUrlTemplate.isNotEmpty
        ? AppConfig.tileUrlTemplate
        : _osmFallback;
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        onTap: onTap == null ? null : (_, p) => onTap!(p),
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
        if (route.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: route,
                strokeWidth: 4,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (final pin in pins)
              Marker(
                point: pin.point,
                width: 44,
                height: 44,
                alignment: Alignment.topCenter,
                child: Icon(pin.icon, color: pin.color, size: 38),
              ),
          ],
        ),
      ],
    );
  }
}
