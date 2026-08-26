import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/foreground/driver_foreground_service.dart';
import '../../../core/location.dart';
import '../../../core/offline/connectivity.dart';
import '../../../core/prefs.dart';
import '../../../shared/request_ring.dart';
import '../../../shared/resilient_poll.dart';
import '../../ride/data/ride_repository.dart';
import '../../ride/domain/models.dart' show Trip;
import '../data/driver_repository.dart';
import '../domain/models.dart';
import 'driver_channel.dart';

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

  /// Whether the driver was online the last time the app had a chance to
  /// record it — set the instant `goOnline()` succeeds, cleared the instant
  /// `goOffline()` runs. Unlike `is_open` for a merchant (a plain DB column
  /// re-read fresh on every app launch), "online" is fronted by a Redis
  /// presence TTL that only a live heartbeat keeps renewed — the app being
  /// killed (swiped from recents) stops that heartbeat, the TTL lapses, and
  /// the backend genuinely forgets the driver within ~60s. Without this
  /// flag, relaunching just shows offline with no hint anything should
  /// resume; with it, launch can silently re-establish presence the same
  /// way a connectivity drop already resumes it mid-session.
  static const _wasOnlineKey = 'saarathi.driver.wasOnline';

  @override
  DriverStatus build() {
    ref.onDispose(() => _heartbeat?.cancel());
    // A connectivity drop while online almost certainly lets the backend's
    // presence TTL (~60s) lapse before the driver even notices — without
    // this they'd stay showing "online" locally, silently receive no more
    // offers, and have no reason to think they need to toggle anything.
    // Resuming automatically the moment the network comes back (only when
    // we were already online going into the drop) means they never have to
    // notice at all.
    ref.listen(connectivityProvider, (prev, next) {
      final wasOffline = prev?.valueOrNull == false;
      final backOnline = next.valueOrNull ?? false;
      if (wasOffline && backOnline && state.online) {
        _resumeOnlineAfterReconnect();
      }
    });
    // Same idea, for the other way presence lapses: the app itself getting
    // killed and relaunched, not just a network blip while it stays alive.
    // Fire-and-forget — this shouldn't hold up the very first frame.
    unawaited(_resumeOnlineAfterRelaunch());
    return const DriverStatus();
  }

  Future<void> _resumeOnlineAfterRelaunch() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (!(prefs.getBool(_wasOnlineKey) ?? false)) return;
    try {
      await goOnline();
    } catch (_) {
      // No location permission, no network yet at launch, etc. — the
      // driver just lands on the home screen showing offline and can
      // toggle manually, same as any other failed goOnline() attempt.
    }
  }

  Future<void> _resumeOnlineAfterReconnect() async {
    try {
      final at = await currentLatLng();
      state = state.copyWith(lastLocation: at);
      await _repo.goOnline(at, state.jobTypes);
      // Already `online` locally throughout — this just re-registers
      // presence server-side and restarts the heartbeat a long-enough
      // outage would have let lapse, without ever flashing a busy state.
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) => _beat());
    } catch (_) {
      // Another reconnect edge (or the driver manually toggling) gets
      // another chance; a `busy` UI signal isn't warranted for a resume the
      // driver never asked for and doesn't need to see fail.
    }
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
      await ref.read(sharedPreferencesProvider).setBool(_wasOnlineKey, true);
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
      // A deliberate offline should never auto-resume on next launch, even
      // if the network call above failed — the driver's own intent, not
      // the backend's confirmation, is what this flag tracks.
      await ref.read(sharedPreferencesProvider).setBool(_wasOnlineKey, false);
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

  Future<List<DriverOffer>> fetchAndRing() async {
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
    // Reflects the live count in the persistent online notification — the
    // closest thing to a status surface while the app is backgrounded,
    // since there's no separate widget/Live-Activity-style area on Android.
    DriverForegroundService.updateStatus(pendingOffers: offers.length);
    return offers;
  }

  final controller = StreamController<List<DriverOffer>>();
  ref.onDispose(controller.close);

  final pollSub = resilientPoll(
    fetch: fetchAndRing,
    interval: const Duration(seconds: 4),
  )
      .map((poll) => poll.value)
      .listen(controller.add, onError: controller.addError);
  ref.onDispose(pollSub.cancel);

  // An immediate out-of-band fetch the moment a dispatch offer is pushed
  // over the driver's WebSocket (see `driver_channel.dart`) — the poll
  // above keeps running underneath as the safety net for whenever a push
  // doesn't arrive (a dropped socket, a missed reconnect window), this just
  // avoids waiting up to 4s for the normal tick to notice the same thing a
  // push already told us about. Reuses `fetchAndRing` so `seen` (and the
  // ring-on-genuinely-new-offer logic) stays correct regardless of which
  // trigger fired.
  final wsSub =
      ref.watch(driverChannelProvider).ofType('offer').listen((_) async {
    try {
      controller.add(await fetchAndRing());
    } catch (_) {
      // The poll loop above will pick this up on its own next tick.
    }
  });
  ref.onDispose(wsSub.cancel);

  yield* controller.stream;
});

/// The id of the trip [driverActiveTripProvider] last auto-navigated to —
/// deliberately a plain, non-autoDispose provider (survives driver_home
/// remounting) rather than comparing against the previous poll value inline
/// in the `ref.listen` callback: that comparison resets to null every time
/// the driver's `_OnlineBoard` remounts (e.g. backing out of the trip
/// screen to it), which re-fires the "new trip" push for the *same*,
/// still-accepted trip every time — a navigate-back-navigate-forward loop.
/// This makes "already navigated to this trip" durable instead.
final lastAutoNavigatedTripProvider = StateProvider<String?>((ref) => null);

/// Polls for a trip already assigned to this driver while they're sitting on
/// the home screen — deliberately *not* gated on the online/offline toggle:
/// a driver who force-quit mid-trip, or whose app crashed, or who just cold-
/// booted the app, still has that trip waiting for them regardless of
/// whatever the local online switch happens to read at that moment (it's a
/// server-side fact, not tied to this device's current presence state). An
/// *instant*-mode offer already sends the driver to the trip screen locally
/// the moment they tap "Accept" — but a *bid* win is decided by the rider
/// accepting the driver's bid, not the driver's own tap, so there's no local
/// trigger to navigate on: the app only otherwise finds out via a push
/// notification, which the driver has to notice and tap. This is the
/// fallback that doesn't depend on that — [_OnlineBoard] watches it and
/// navigates automatically the moment a trip appears here.
final driverActiveTripProvider =
    StreamProvider.autoDispose<Trip?>((ref) async* {
  ref.keepAlive();
  final repo = ref.watch(rideRepositoryProvider);
  yield* resilientPoll(
    fetch: () async {
      final trips = await repo.myTrips();
      return trips.where((t) => t.isActive && t.driverId != null).firstOrNull;
    },
    interval: const Duration(seconds: 4),
  ).map((poll) => poll.value);
});
