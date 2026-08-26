import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'map_view.dart';

/// A small, static pickup→destination preview — not live, not fullscreen,
/// just enough to place a finished trip or order's route in context on a
/// details page. Reuses [MapView] as-is (auto-fit camera, no locate/recenter
/// buttons, no tap handler) rather than a separate lightweight map
/// implementation, so it stays visually consistent with the live map.
class MiniRouteMap extends StatelessWidget {
  const MiniRouteMap({
    super.key,
    required this.origin,
    required this.dest,
    this.route = const [],
    this.height = 180,
  });

  final LatLng origin;
  final LatLng dest;
  final List<LatLng> route;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: height,
        child: MapView(
          center: origin,
          route: route,
          autoFitPins: true,
          fitPadding: const EdgeInsets.all(28),
          pins: [
            MapPin(origin, Icons.emoji_people_rounded, scheme.primary),
            MapPin(dest, Icons.sports_score_rounded, scheme.secondary),
          ],
        ),
      ),
    );
  }
}
