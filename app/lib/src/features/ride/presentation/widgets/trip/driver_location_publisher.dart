import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter/widgets.dart';

import '../../../../../core/location.dart';
import '../../../../../core/offline/connectivity.dart';
import '../../../application/trip_ws.dart';
import '../../../data/ride_repository.dart';

/// While a driver is on an active trip, tracks local GPS continuously (for
/// the driver's own map/nav camera) and posts to the backend roughly every
/// 100m of movement (or every 30s if stationary), rather than on a fixed
/// timer regardless of distance.
class DriverLocationPublisher extends ConsumerStatefulWidget {
  const DriverLocationPublisher({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<DriverLocationPublisher> createState() =>
      _DriverLocationPublisherState();
}

class _DriverLocationPublisherState
    extends ConsumerState<DriverLocationPublisher> {
  // Matches `tripDriverPositionProvider`'s own threshold (trip_ws.dart) — a
  // stopped/crawling driver's GPS heading is noise, not a real turn, and
  // would jitter the nav camera exactly where it most needs to hold steady
  // (waiting at a light).
  static const _minHeadingSpeedMs = 1.0;

  // Other parties (the rider, dispatch) don't need every raw fix — a post
  // roughly every 100m of actual movement is plenty, and cuts backend/
  // battery load compared to posting on a fixed timer regardless of whether
  // the driver has gone anywhere.
  static const _postDistanceMeters = 100.0;
  // A stationary driver (parked, waiting at a light for a while) would
  // otherwise never post again once they stop moving 100m at a time — this
  // keeps the rider's/dispatch's view of the driver from going stale for
  // good while genuinely stopped.
  static const _postKeepAlive = Duration(seconds: 30);
  static const _distance = Distance();

  StreamSubscription<Position>? _sub;
  ProviderSubscription<AsyncValue<double?>>? _compassSub;
  Timer? _keepAliveTimer;
  Timer? _retryTimer;
  ProviderSubscription<AsyncValue<bool>>? _connSub;
  Position? _latest;
  Position? _lastPosted;
  double? _lastHeading;

  /// The device's own magnetometer heading — unlike GPS course-over-ground
  /// (`Position.heading`), this is meaningful even standing still, so it's
  /// what backs [_lastHeading] below [_minHeadingSpeedMs] instead of just
  /// freezing on whatever the last fast-enough GPS fix reported. Google
  /// Maps does the same blend (GPS course while moving, compass while
  /// stopped/crawling) for exactly this reason.
  double? _compassHeading;

  // The most recent position that failed to reach the backend — retried
  // with backoff below, and immediately on reconnect, until it (or a
  // fresher point superseding it) actually lands. Without this a failed
  // ping was just gone for good; the rider/dispatch view of this driver
  // would stay frozen at whatever the last *successful* post was for the
  // entire offline stretch, even after connectivity came back.
  Position? _pendingRetry;
  int _retryAttempt = 0;

  // The position stream itself can die mid-trip — most commonly the OS
  // location permission being revoked live (Android allows this without
  // killing the app) or the GPS toggle turned off. Previously this just
  // silently stopped: no `onError` meant the stream terminated and the
  // driver's marker froze in place for the rest of the trip with no
  // indication anything was wrong. Restarting re-checks permission/service
  // each time, so it recovers on its own the moment either is restored.
  Timer? _streamRestartTimer;

  @override
  void initState() {
    super.initState();
    _start();
    _keepAliveTimer = Timer.periodic(_postKeepAlive, (_) {
      final pos = _latest;
      if (pos != null) _post(pos, previous: _lastPosted);
    });
    _connSub = ref.listenManual(connectivityProvider, (prev, next) {
      // Same in-flight-event-vs-dispose race as the compass listener below.
      if (!mounted) return;
      final backOnline = next.value ?? false;
      final pending = _pendingRetry;
      if (backOnline && pending != null) {
        _retryTimer?.cancel();
        _retryAttempt = 0;
        _post(pending, previous: _lastPosted);
      }
    });
  }

  Future<void> _start() async {
    // Not `currentLatLng()` here — it discards everything but lat/lng, and
    // the navigation camera (heading-up rotation) needs `heading`/`speed`
    // too. Same permission/service gating as `currentLatLng()`, just
    // keeping the full `Position`.
    if (!await ensureLocationPermission() ||
        !await Geolocator.isLocationServiceEnabled()) {
      return;
    }
    if (!mounted) return;
    // A continuous local stream, not a poll: `localDriverPositionProvider`
    // (read directly by this driver's own map/nav camera) updates the
    // instant a new fix lands — this is what keeps the driver's own vehicle
    // marker moving offline or on a bad connection, since it no longer
    // depends on `POST location` reaching the backend at all.
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition,
        onError: (_) => _restartStream(), onDone: _restartStream);
    _compassSub = ref.listenManual(compassHeadingProvider, (prev, next) {
      // `compassHeadingProvider` is a keep-alive, app-lifetime provider — an
      // event can still be in flight the instant this widget's dispose()
      // closes the subscription, landing here just after `ref` is no longer
      // safe to use ("Looking up a deactivated widget's ancestor is
      // unsafe"). `close()` stops *future* events, not one already queued.
      if (!mounted) return;
      final heading = next.value;
      if (heading == null) return;
      _compassHeading = heading;
      // `Geolocator.getPositionStream`'s `distanceFilter: 5` above means
      // `_onPosition` (the only other place that writes to
      // `localDriverPositionProvider`) simply never fires while genuinely
      // stationary — exactly the case this compass blend exists for. Without
      // pushing an update from here too, the vehicle icon would keep
      // reading a heading from whatever the last-moving GPS fix reported
      // and never actually visibly turn to face the compass while stopped.
      final pos = _latest;
      if (pos != null && pos.speed <= _minHeadingSpeedMs) {
        _lastHeading = heading;
        ref.read(localDriverPositionProvider.notifier).state = DriverPosition(
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
      // Moving fast enough that GPS course-over-ground is trustworthy —
      // preferred over compass here since a moving vehicle's actual heading
      // can differ from wherever the phone itself happens to be pointed
      // (mount angle, being held at an angle, etc.).
      _lastHeading = pos.heading;
    } else if (_compassHeading != null) {
      // Stopped/crawling — GPS course is noise here, but the compass still
      // reads a real heading, so use it instead of freezing on whatever the
      // last fast-enough GPS fix reported.
      _lastHeading = _compassHeading;
    }
    ref.read(localDriverPositionProvider.notifier).state = DriverPosition(
      point: LatLng(pos.latitude, pos.longitude),
      heading: _lastHeading,
      speed: pos.speed,
    );
    final last = _lastPosted;
    final moved = last == null ||
        _distance.as(LengthUnit.Meter, LatLng(last.latitude, last.longitude),
                LatLng(pos.latitude, pos.longitude)) >=
            _postDistanceMeters;
    if (moved) _post(pos, previous: last);
  }

  Future<void> _post(Position pos, {required Position? previous}) async {
    _lastPosted = pos;
    try {
      // `_lastHeading` (GPS course while moving, compass while stopped/
      // crawling) instead of raw `pos.heading` — otherwise this blend would
      // only ever benefit the driver's own screen, and the rider (who only
      // ever sees whatever heading gets posted here) would still get a
      // heading that freezes every time the driver stops.
      await ref.read(rideRepositoryProvider).postLocation(
            widget.tripId,
            pos.latitude,
            pos.longitude,
            heading: _lastHeading,
            speed: pos.speed,
          );
      // A successful post means the backend is caught up — any earlier
      // failed attempt is now moot, since this point is at least as fresh.
      _pendingRetry = null;
      _retryAttempt = 0;
      _retryTimer?.cancel();
    } catch (_) {
      // Offline or a transient failure — the driver's own nav already keeps
      // moving via `localDriverPositionProvider` regardless. Roll back so
      // the next 100m is measured from the last position that actually made
      // it to the backend, not this failed attempt, and keep retrying this
      // point (with backoff, and immediately on reconnect) until it lands.
      _lastPosted = previous;
      _pendingRetry = pos;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final attempt = _retryAttempt++;
    final delaySecs = attempt >= 4 ? 30 : (1 << (attempt + 1)); // 2,4,8,16,30…
    _retryTimer = Timer(Duration(seconds: delaySecs), () {
      final pos = _pendingRetry;
      if (pos != null) _post(pos, previous: _lastPosted);
    });
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
    _keepAliveTimer?.cancel();
    _retryTimer?.cancel();
    _streamRestartTimer?.cancel();
    _connSub?.close();
    // Don't leak this trip's last fix into whatever comes next (a new trip,
    // or the driver going idle) — the local nav camera should show nothing
    // until a fresh trip actually starts reporting again.
    ref.read(localDriverPositionProvider.notifier).state = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
