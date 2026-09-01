import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../../../core/location.dart';
import '../../../application/trip_ws.dart';

/// Invisible: feeds the rider's own live position + device heading to
/// [localSelfPositionProvider] while there's no driver marker yet to show
/// instead — the rider's "own compass" during the search/pre-assignment
/// phase. Same GPS/compass blend as [_DriverLocationPublisher] but nothing
/// is posted to the backend — this is purely a local display concern, the
/// rider's own location was never something the backend needed.
class SelfLocationWatcher extends ConsumerStatefulWidget {
  const SelfLocationWatcher({super.key});

  @override
  ConsumerState<SelfLocationWatcher> createState() =>
      _SelfLocationWatcherState();
}

class _SelfLocationWatcherState extends ConsumerState<SelfLocationWatcher> {
  static const _minHeadingSpeedMs = 1.0;

  StreamSubscription<Position>? _sub;
  ProviderSubscription<AsyncValue<double?>>? _compassSub;
  Position? _latest;
  double? _compassHeading;
  double? _lastHeading;

  // See `_DriverLocationPublisherState._streamRestartTimer` — without an
  // `onError`/`onDone` handler, a live permission revocation or GPS toggle
  // silently kills this stream and the rider's own position/heading arrow
  // freezes for the rest of the trip.
  Timer? _streamRestartTimer;

  @override
  void initState() {
    super.initState();
    _start();
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
    _compassSub = ref.listenManual(compassHeadingProvider, (prev, next) {
      // Same in-flight-event-vs-dispose race noted on
      // `_DriverLocationPublisherState`'s own compass listener.
      if (!mounted) return;
      final heading = next.value;
      if (heading == null) return;
      _compassHeading = heading;
      final pos = _latest;
      if (pos != null && pos.speed <= _minHeadingSpeedMs) {
        _lastHeading = heading;
        ref.read(localSelfPositionProvider.notifier).state = DriverPosition(
          point: LatLng(pos.latitude, pos.longitude),
          heading: _lastHeading,
          speed: pos.speed,
        );
      }
    });
  }

  void _onPosition(Position pos) {
    _latest = pos;
    if (pos.speed > _minHeadingSpeedMs) {
      _lastHeading = pos.heading;
    } else if (_compassHeading != null) {
      _lastHeading = _compassHeading;
    }
    ref.read(localSelfPositionProvider.notifier).state = DriverPosition(
      point: LatLng(pos.latitude, pos.longitude),
      heading: _lastHeading,
      speed: pos.speed,
    );
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
    _compassSub?.close();
    _streamRestartTimer?.cancel();
    ref.read(localSelfPositionProvider.notifier).state = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
