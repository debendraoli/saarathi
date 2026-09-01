import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../../../core/location.dart';
import '../../../data/ride_repository.dart';

/// Invisible: posts the rider's own live GPS to the trip channel (via the
/// same role-agnostic `POST .../location` endpoint [_DriverLocationPublisher]
/// already uses) once they've opted in via [riderShareLocationProvider] —
/// lets the driver see exactly where the rider is instead of only the
/// static pickup pin they selected, useful when the rider is walking to a
/// meeting point or the pin itself is imprecise. Deliberately simpler than
/// [_DriverLocationPublisher]: no compass blend (a walking rider doesn't
/// need a vehicle-accurate heading) and no dedicated retry-with-backoff
/// queue (this is a supplementary display signal, not the trip's
/// authoritative tracking — a missed post is just caught by the next
/// moved-30m fix or the keep-alive tick, no need to chase down one specific
/// failed point the way the driver's own position-of-record does).
class RiderLocationPublisher extends ConsumerStatefulWidget {
  const RiderLocationPublisher({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<RiderLocationPublisher> createState() =>
      _RiderLocationPublisherState();
}

class _RiderLocationPublisherState
    extends ConsumerState<RiderLocationPublisher> {
  // A walking rider moves much slower than a vehicle and precision matters
  // more for a meetup point — tighter than the driver publisher's 100m.
  static const _postDistanceMeters = 30.0;
  static const _postKeepAlive = Duration(seconds: 20);
  static const _distance = Distance();

  StreamSubscription<Position>? _sub;
  Timer? _keepAliveTimer;
  Timer? _streamRestartTimer;
  Position? _latest;
  Position? _lastPosted;

  @override
  void initState() {
    super.initState();
    _start();
    _keepAliveTimer = Timer.periodic(_postKeepAlive, (_) {
      final pos = _latest;
      if (pos != null) _post(pos);
    });
  }

  Future<void> _start() async {
    if (!await ensureLocationPermission() ||
        !await Geolocator.isLocationServiceEnabled()) {
      return;
    }
    if (!mounted) return;
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition,
        onError: (_) => _restartStream(), onDone: _restartStream);
  }

  void _onPosition(Position pos) {
    _latest = pos;
    final last = _lastPosted;
    final moved = last == null ||
        _distance.as(LengthUnit.Meter, LatLng(last.latitude, last.longitude),
                LatLng(pos.latitude, pos.longitude)) >=
            _postDistanceMeters;
    if (moved) _post(pos);
  }

  Future<void> _post(Position pos) async {
    final previous = _lastPosted;
    _lastPosted = pos;
    try {
      await ref.read(rideRepositoryProvider).postLocation(
            widget.tripId,
            pos.latitude,
            pos.longitude,
            heading: pos.heading,
            speed: pos.speed,
          );
    } catch (_) {
      // Roll back so the next moved-30m check is measured from the last
      // position that actually reached the backend, not this failed one —
      // same reasoning as _DriverLocationPublisherState._post. Without this,
      // a single failed post silently rebased the threshold onto a point
      // the backend never saw, swallowing the rider's next 30m of movement
      // until the keep-alive tick happened to catch up.
      _lastPosted = previous;
    }
  }

  void _restartStream() {
    _sub?.cancel();
    _sub = null;
    if (!mounted) return;
    _streamRestartTimer?.cancel();
    _streamRestartTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _keepAliveTimer?.cancel();
    _streamRestartTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
