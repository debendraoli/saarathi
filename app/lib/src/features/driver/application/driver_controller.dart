import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/foreground/driver_foreground_service.dart';
import '../../../core/location.dart';
import '../../../shared/request_ring.dart';
import '../../../shared/resilient_poll.dart';
import '../data/driver_repository.dart';
import '../domain/models.dart';

class DriverStatus {
  const DriverStatus(
      {this.online = false,
      this.busy = false,
      this.jobTypes = const ['ride'],
      this.lastLocation});
  final bool online;
  final bool busy;
  final List<String> jobTypes;

  /// The driver's own last-known position — part of state (not a plain
  /// field) so watchers like the radar map rebuild as it updates.
  final LatLng? lastLocation;

  DriverStatus copyWith(
          {bool? online,
          bool? busy,
          List<String>? jobTypes,
          LatLng? lastLocation}) =>
      DriverStatus(
        online: online ?? this.online,
        busy: busy ?? this.busy,
        jobTypes: jobTypes ?? this.jobTypes,
        lastLocation: lastLocation ?? this.lastLocation,
      );
}

class DriverController extends Notifier<DriverStatus> {
  Timer? _heartbeat;

  @override
  DriverStatus build() {
    ref.onDispose(() => _heartbeat?.cancel());
    return const DriverStatus();
  }

  DriverRepository get _repo => ref.read(driverRepositoryProvider);

  Future<void> toggleOnline() => state.online ? goOffline() : goOnline();

  Future<void> goOnline() async {
    state = state.copyWith(busy: true);
    try {
      final at = await currentLatLng();
      state = state.copyWith(lastLocation: at);
      await _repo.goOnline(at, state.jobTypes);
      state = state.copyWith(online: true, busy: false);
      // Presence keep-alive (backend TTL is ~60s; beat well inside it).
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) => _beat());
      // Sticky foreground notification keeps us alive to receive offers.
      await DriverForegroundService.start();
    } catch (_) {
      state = state.copyWith(busy: false);
      rethrow;
    }
  }

  Future<void> goOffline() async {
    state = state.copyWith(busy: true);
    _heartbeat?.cancel();
    await DriverForegroundService.stop();
    try {
      await _repo.goOffline();
    } finally {
      state = state.copyWith(online: false, busy: false);
    }
  }

  Future<void> _beat() async {
    try {
      final at = await currentLatLng();
      state = state.copyWith(lastLocation: at);
      await _repo.heartbeat(at, state.jobTypes);
    } catch (_) {
      // A missed beat is fine; the next tick retries.
    }
  }

  LatLng? get lastLocation => state.lastLocation;
}

final driverControllerProvider =
    NotifierProvider<DriverController, DriverStatus>(DriverController.new);

/// Polls dispatch offers while the driver is online (short TTL, so poll often).
/// Rings once per genuinely new offer id (not every poll tick) — comparing
/// against the previous snapshot lives here, colocated with the polling loop
/// itself, rather than duplicated in whatever widget happens to be watching.
///
/// Self-recovers from transient failures via `resilientPoll`: a flaky tick
/// keeps showing the last-known offers instead of blanking the list to
/// empty (which would silently drop a live offer card off screen).
final driverOffersProvider =
    StreamProvider.autoDispose<List<DriverOffer>>((ref) async* {
  final online = ref.watch(driverControllerProvider).online;
  if (!online) {
    RequestRing.stop();
    yield const [];
    return;
  }
  // Stay alive with zero widget watchers — otherwise navigating away from
  // driver_home mid-offer disposes this (autoDispose's default) and silently
  // stops the ring/vibration while the driver is still online.
  ref.keepAlive();
  final repo = ref.watch(driverRepositoryProvider);
  // Null (not empty) until the first fetch lands — an empty starting set
  // would make every offer already live when the driver opens the app (or
  // this provider gets recreated, e.g. going back online) look "new" against
  // it, ringing immediately instead of only on a genuine new arrival.
  Set<String>? seen;
  ref.onDispose(RequestRing.stop);
  yield* resilientPoll(
    fetch: () async {
      final offers = await repo.offers();
      final ids = offers.map((o) => o.tripId).toSet();
      final lastSeen = seen;
      if (lastSeen != null) {
        if (ids.difference(lastSeen).isNotEmpty) {
          RequestRing.play();
        } else if (ids.isEmpty) {
          RequestRing.stop();
        }
      }
      seen = ids;
      return offers;
    },
    interval: const Duration(seconds: 4),
  ).map((poll) => poll.value);
});
