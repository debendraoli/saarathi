import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../domain/models.dart';
import 'trip_channel.dart';

/// Live driver position over the shared trip channel. Silent until a driver is
/// assigned and starts posting `location` frames.
final tripLocationProvider =
    StreamProvider.autoDispose.family<LatLng, String>((ref, tripId) {
  final channel = ref.watch(tripChannelProvider(tripId));
  return channel
      .ofType('location')
      .map((m) => LatLng(asDouble(m['lat']), asDouble(m['lng'])));
});

/// A driver's live position plus heading/speed — the richer counterpart to
/// [tripLocationProvider], for the navigation camera (heading-up rotation)
/// on the trip screen. [tripLocationProvider] stays bare-`LatLng` since its
/// only other consumer (`rider_home.dart`'s active-trip card) has no use
/// for heading.
class DriverPosition {
  const DriverPosition({required this.point, this.heading, this.speed});
  final LatLng point;
  final double? heading;
  final double? speed;
}

/// GPS heading is unreliable/jittery below this speed (m/s) — a stopped or
/// crawling driver's reported heading swings wildly frame to frame. Below
/// this threshold the last trustworthy heading is kept instead of snapping
/// the nav camera to noise.
const _minHeadingSpeedMs = 1.0;

final tripDriverPositionProvider = StreamProvider.autoDispose
    .family<DriverPosition, String>((ref, tripId) {
  final channel = ref.watch(tripChannelProvider(tripId));
  double? lastHeading;
  return channel.ofType('location').map((m) {
    final speed = (m['speed'] as num?)?.toDouble();
    final rawHeading = (m['heading'] as num?)?.toDouble();
    if (rawHeading != null && (speed ?? 0) > _minHeadingSpeedMs) {
      lastHeading = rawHeading;
    }
    return DriverPosition(
      point: LatLng(asDouble(m['lat']), asDouble(m['lng'])),
      heading: lastHeading,
      speed: speed,
    );
  });
});
