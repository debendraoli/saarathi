import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/foreground/driver_foreground_service.dart';
import '../../../core/location.dart';
import '../../../shared/request_ring.dart';
import '../data/driver_repository.dart';
import '../domain/models.dart';

class DriverStatus {
  const DriverStatus(
      {this.online = false, this.busy = false, this.jobTypes = const ['ride']});
  final bool online;
  final bool busy;
  final List<String> jobTypes;

  DriverStatus copyWith({bool? online, bool? busy, List<String>? jobTypes}) =>
      DriverStatus(
        online: online ?? this.online,
        busy: busy ?? this.busy,
        jobTypes: jobTypes ?? this.jobTypes,
      );
}

class DriverController extends Notifier<DriverStatus> {
  Timer? _heartbeat;
  LatLng? _last;

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
      _last = at;
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
      _last = at;
      await _repo.heartbeat(at, state.jobTypes);
    } catch (_) {
      // A missed beat is fine; the next tick retries.
    }
  }

  LatLng? get lastLocation => _last;
}

final driverControllerProvider =
    NotifierProvider<DriverController, DriverStatus>(DriverController.new);

/// Polls dispatch offers while the driver is online (short TTL, so poll often).
/// Rings once per genuinely new offer id (not every poll tick) — comparing
/// against the previous snapshot lives here, colocated with the polling loop
/// itself, rather than duplicated in whatever widget happens to be watching.
final driverOffersProvider =
    StreamProvider.autoDispose<List<DriverOffer>>((ref) async* {
  final online = ref.watch(driverControllerProvider).online;
  if (!online) {
    RequestRing.stop();
    yield const [];
    return;
  }
  final repo = ref.watch(driverRepositoryProvider);
  var seen = <String>{};
  ref.onDispose(RequestRing.stop);
  while (true) {
    try {
      final offers = await repo.offers();
      final ids = offers.map((o) => o.tripId).toSet();
      if (ids.difference(seen).isNotEmpty) {
        RequestRing.play();
      } else if (ids.isEmpty) {
        RequestRing.stop();
      }
      seen = ids;
      yield offers;
    } catch (_) {
      yield const [];
    }
    await Future<void>.delayed(const Duration(seconds: 4));
  }
});
