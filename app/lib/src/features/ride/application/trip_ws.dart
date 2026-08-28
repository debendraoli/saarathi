import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:latlong2/latlong.dart';

import '../domain/models.dart';
import 'ride_controller.dart' show tripStreamProvider;
import 'trip_channel.dart';

/// Live driver position over the shared trip channel. Silent until a driver is
/// assigned and starts posting `location` frames.
///
/// Filtered to the trip's own `driverId` (the frame's `by` field, stamped
/// server-side — see `tracking.rs`'s `do_post_location`) — the channel's
/// `location` frames are no longer driver-only now that a rider can also
/// post their own via [tripRiderPositionProvider]'s publisher, and without
/// this filter either party's posts would get misread as the other's.
final tripLocationProvider =
    StreamProvider.autoDispose.family<LatLng, String>((ref, tripId) {
  final channel = ref.watch(tripChannelProvider(tripId));
  final driverId = ref.watch(tripStreamProvider(tripId)).value?.driverId;
  return channel
      .ofType('location')
      .where((m) => driverId != null && m['by'] == driverId)
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

/// The driver's own live position, sourced directly from local device GPS
/// (see `_DriverLocationPublisher` in trip_screen.dart) rather than the
/// round-trip through `POST location` → backend → this trip's WebSocket that
/// [tripDriverPositionProvider] depends on. A driver navigating their own
/// trip should see their own marker/camera keep moving from local GPS alone
/// — offline or not, on a slow connection or not — instead of freezing
/// whenever that round-trip is disrupted. Only ever set while the driver has
/// an active trip; `null` otherwise (including for a rider, who has no local
/// GPS of the *driver* and must always use the WS-fed provider instead).
final localDriverPositionProvider =
    StateProvider<DriverPosition?>((ref) => null);

/// Whether the rider has opted in to sharing their live location with the
/// driver for this trip (the booking sheet's toggle) — purely local UI
/// state, not persisted to the backend; the toggle just controls whether
/// [RiderLocationPublisher] runs. Defaults off each time this trip is first
/// watched (a fresh trip always starts opted out).
final riderShareLocationProvider =
    StateProvider.autoDispose.family<bool, String>((ref, tripId) => false);

/// The rider's own live position + device heading — shown as their own
/// "you are here" arrow while waiting for a driver, since there's nothing
/// else on the map yet to orient by (see `_SelfLocationWatcher` in
/// trip_screen.dart). Superseded by the driver's own marker the moment one
/// is assigned; `null` otherwise, including for a driver or merchant (who
/// see the *other* party's heading instead, not their own).
final localSelfPositionProvider = StateProvider<DriverPosition?>((ref) => null);

/// Filtered to the trip's own `driverId` — see [tripLocationProvider]'s doc
/// comment for why this filter exists now.
final tripDriverPositionProvider =
    StreamProvider.autoDispose.family<DriverPosition, String>((ref, tripId) {
  final channel = ref.watch(tripChannelProvider(tripId));
  final driverId = ref.watch(tripStreamProvider(tripId)).value?.driverId;
  double? lastHeading;
  return channel
      .ofType('location')
      .where((m) => driverId != null && m['by'] == driverId)
      .map((m) {
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

/// The rider's live position over the shared trip channel, filtered to the
/// trip's own `riderId` — the driver-side counterpart to
/// [tripDriverPositionProvider], fed by [RiderLocationPublisher] (in
/// trip_screen.dart) once the rider opts in via the booking sheet's
/// "share my location" toggle. Silent until they do; a rider who never
/// opts in simply never posts a `location` frame with their own id.
final tripRiderPositionProvider =
    StreamProvider.autoDispose.family<DriverPosition, String>((ref, tripId) {
  final channel = ref.watch(tripChannelProvider(tripId));
  final riderId = ref.watch(tripStreamProvider(tripId)).value?.riderId;
  double? lastHeading;
  return channel
      .ofType('location')
      .where((m) => riderId != null && m['by'] == riderId)
      .map((m) {
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
