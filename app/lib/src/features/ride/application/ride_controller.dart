import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/api_client.dart';
import '../../../core/offline/connectivity.dart';
import '../../../shared/geocode_cache.dart';
import '../../../shared/paged_notifier.dart';
import '../../../shared/provider_retry.dart';
import '../../../shared/resilient_poll.dart';
import '../../places/data/places_repository.dart';
import '../data/ride_repository.dart';
import '../domain/models.dart';

/// One-shot fare estimate for a drafted ride (auto-disposed when unused).
/// Rapidly switching vehicle class fires one of these per class — the
/// CancelToken aborts a class's in-flight request the moment its family
/// instance is no longer watched (superseded by a different draft), instead
/// of letting an abandoned quote finish on the wire for nothing.
final fareEstimateProvider =
    FutureProvider.autoDispose.family<FareEstimate, RideDraft>((ref, draft) {
  final cancelToken = CancelToken();
  ref.onDispose(cancelToken.cancel);
  return ref
      .watch(rideRepositoryProvider)
      .estimate(draft, cancelToken: cancelToken);
}, retry: shortNetworkRetry);

/// An ordered path (pickup → stops → destination) + profile for a route lookup.
/// Value equality over the point list so identical paths share one request and
/// don't refetch on every rebuild.
class RouteQuery {
  const RouteQuery(this.points, this.vehicleClass);
  final List<LatLng> points;
  final String vehicleClass;

  @override
  bool operator ==(Object other) =>
      other is RouteQuery &&
      other.vehicleClass == vehicleClass &&
      _samePoints(other.points, points);

  @override
  int get hashCode => Object.hash(vehicleClass, Object.hashAll(points));

  static bool _samePoints(List<LatLng> a, List<LatLng> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Road-following polyline for a pickup → stops → destination path.
final routeGeometryProvider =
    FutureProvider.autoDispose.family<RouteGeometry, RouteQuery>((ref, q) {
  return ref
      .watch(rideRepositoryProvider)
      .routeGeometry(q.points, vehicleClass: q.vehicleClass);
}, retry: shortNetworkRetry);

/// The full road route (geometry + turn-by-turn steps) for the fullscreen
/// navigation view — same query shape as [routeGeometryProvider], separate
/// provider since most callers only need the plain polyline.
final roadRouteProvider =
    FutureProvider.autoDispose.family<RoadRoute, RouteQuery>((ref, q) {
  return ref
      .watch(rideRepositoryProvider)
      .roadRoute(q.points, vehicleClass: q.vehicleClass);
}, retry: shortNetworkRetry);

/// Two points to route between for a live ETA. Value equality (same shape as
/// [RouteQuery]) means an unchanged driver position reuses the cached
/// result instead of re-fetching — no manual throttling needed, the ETA
/// simply re-requests exactly when the driver's live location actually
/// moves.
class EtaQuery {
  const EtaQuery(this.from, this.to);
  final LatLng from;
  final LatLng to;

  @override
  bool operator ==(Object other) =>
      other is EtaQuery && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// Live distance/duration between two points — see [EtaQuery].
final tripEtaProvider =
    FutureProvider.autoDispose.family<RouteEta, EtaQuery>((ref, q) {
  return ref.watch(rideRepositoryProvider).routeEta(q.from, q.to);
}, retry: shortNetworkRetry);

/// One-shot fetch for a finished trip's details page — a completed,
/// cancelled, or no-driver trip's status/fare never changes again, so
/// there's nothing worth the live-poll machinery below re-fetching for.
/// (Participant/driver info for the same page can still reuse the existing
/// [tripParticipantsProvider] further below — it only re-fetches on a
/// status change, which a finished trip's details page will never see.)
final tripDetailsProvider =
    FutureProvider.autoDispose.family<Trip, String>((ref, id) {
  return ref.watch(rideRepositoryProvider).trip(id);
}, retry: shortNetworkRetry);

/// Single underlying poll loop for a trip — [tripStreamProvider] and
/// [tripStaleProvider] both derive from this one fetch cycle rather than
/// each polling independently.
final _tripPollProvider =
    StreamProvider.autoDispose.family<Poll<Trip>, String>((ref, id) {
  final repo = ref.watch(rideRepositoryProvider);
  return resilientPoll(
    fetch: () => repo.trip(id),
    interval: const Duration(seconds: 3),
    stopWhen: (trip) => !trip.isActive,
  );
});

/// The live trip, self-recovering from transient network failures — a flaky
/// tick keeps showing the last-known trip instead of erroring the whole
/// screen. See [tripStaleProvider] to show a small "reconnecting" indicator
/// during that window instead of just going silent.
final tripStreamProvider =
    Provider.autoDispose.family<AsyncValue<Trip>, String>((ref, id) {
  return ref.watch(_tripPollProvider(id)).whenData((poll) => poll.value);
});

/// True while the trip screen is showing a stale (last-known) value because
/// the most recent poll failed.
final tripStaleProvider = Provider.autoDispose.family<bool, String>((ref, id) {
  return ref.watch(_tripPollProvider(id)).value?.stale ?? false;
});

/// A driver-side status transition (arriving → in_progress → completed)
/// applied locally the instant the swipe completes, before the `POST status`
/// that makes it real has even been attempted — see [TripStatusUpdater].
/// Cleared automatically once the poll confirms the same status (or a
/// genuine rejection reverts it), never left to drift from the truth
/// indefinitely.
final optimisticTripStatusProvider =
    StateProvider.family<TripStatus?, String>((ref, tripId) => null);

/// [tripStreamProvider] with any pending [optimisticTripStatusProvider]
/// layered on top — this, not the bare poll, is what the trip screen should
/// actually watch, so a driver's own swipe shows up immediately regardless
/// of how long the real status-update request takes (or whether it's
/// currently offline and queued in [TripStatusUpdater]).
final effectiveTripProvider =
    Provider.autoDispose.family<AsyncValue<Trip>, String>((ref, tripId) {
  final base = ref.watch(tripStreamProvider(tripId));
  final optimistic = ref.watch(optimisticTripStatusProvider(tripId));
  // The moment the real poll confirms this status, the override has served
  // its purpose — clearing it here (rather than leaving it to linger until
  // the *next* optimistic swipe overwrites it) keeps this provider a pure
  // function of "what's true right now", not "what was ever asserted".
  ref.listen(tripStreamProvider(tripId), (prev, next) {
    if (optimistic != null && next.value?.status == optimistic) {
      ref.read(optimisticTripStatusProvider(tripId).notifier).state = null;
    }
  });
  if (optimistic == null) return base;
  return base.whenData((trip) =>
      trip.status == optimistic ? trip : trip.copyWith(status: optimistic));
});

/// Retries a status-update POST (arriving/in_progress/completed/cancelled)
/// until it lands — backing [optimisticTripStatusProvider] so "swipe to
/// start/complete" (driver) or "cancel ride" (either party) never blocks on
/// the network. One instance per trip, created lazily and kept alive for
/// the app's lifetime (a trip's status only ever changes a handful of
/// times, so there's nothing meaningful to dispose): unlike a per-widget
/// retry, this survives whatever UI triggered it disappearing the instant
/// the optimistic status takes effect (e.g. advancing past `inProgress`
/// immediately unmounts the "complete trip" swipe that triggered it; a
/// cancel navigates the whole trip screen away immediately).
final tripStatusUpdaterProvider =
    Provider.family<TripStatusUpdater, String>((ref, tripId) {
  return TripStatusUpdater(ref, tripId);
});

class TripStatusUpdater {
  TripStatusUpdater(this._ref, this.tripId);
  final Ref _ref;
  final String tripId;

  Timer? _retryTimer;
  ProviderSubscription<AsyncValue<bool>>? _connSub;
  int _attempt = 0;
  String? _pending;
  String? _pendingReason;

  /// Applies [status] optimistically and attempts the real update — call
  /// this instead of hitting `rideRepositoryProvider.updateStatus`/`cancel`
  /// directly from a swipe control or a cancel button. [reason] is only
  /// meaningful for `status == 'cancelled'`.
  void update(String status, {String? reason}) {
    // TripStatus.fromWire, not a naive `s.name == status` match — the
    // latter compares against Dart's own camelCase enum identifier
    // (`TripStatus.inProgress.name == "inProgress"`), which never matches
    // the snake_case wire string this method is actually called with
    // (`'in_progress'`). That silently set the optimistic override to
    // `TripStatus.unknown` on every "Start trip" tap — which every
    // status-gated widget on this screen (the next swipe, the cancel
    // button, the fullscreen-nav button, `trip.isActive` itself) treats as
    // "hide" — and it never self-corrected: the real poll's *correct*
    // status doesn't match the *wrong* optimistic one either, so the
    // override-clearing listener below never fired. Confirmed live as
    // "all the buttons are gone" after starting a trip, across several
    // separate reports that looked like unrelated layout bugs.
    _ref.read(optimisticTripStatusProvider(tripId).notifier).state =
        TripStatus.fromWire(status);
    _pending = status;
    _pendingReason = reason;
    _connSub ??= _ref.listen(connectivityProvider, (prev, next) {
      if ((next.value ?? false) && _pending != null) {
        _retryTimer?.cancel();
        _attempt = 0;
        _attemptRun();
      }
    });
    _retryTimer?.cancel();
    _attempt = 0;
    _attemptRun();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final attempt = _attempt++;
    final delaySecs = attempt >= 4 ? 30 : (1 << (attempt + 1)); // 2,4,8,16,30…
    _retryTimer = Timer(Duration(seconds: delaySecs), _attemptRun);
  }

  Future<void> _attemptRun() async {
    final status = _pending;
    if (status == null) return;
    try {
      await _ref
          .read(rideRepositoryProvider)
          .updateStatus(tripId, status, reason: _pendingReason);
      _pending = null;
      _pendingReason = null;
      _retryTimer?.cancel();
      _ref.invalidate(_tripPollProvider(tripId));
    } on ApiException catch (e) {
      if (e.isNetwork) {
        _scheduleRetry();
      } else {
        _pending = null;
        _pendingReason = null;
        _ref.read(optimisticTripStatusProvider(tripId).notifier).state = null;
      }
    } catch (_) {
      _scheduleRetry();
    }
  }
}

/// Restarts the actual poll loop after it's given up (past
/// `maxInitialFailures` with no value ever fetched) — invalidating
/// [tripStreamProvider] alone wouldn't do this, since it's a thin derived
/// view over this provider, not the poll loop itself.
void retryTripPoll(WidgetRef ref, String id) =>
    ref.invalidate(_tripPollProvider(id));

/// Counterpart identity for the sticky in-trip card. Re-fetches only when the
/// trip's status actually changes (e.g. phone visibility flips once a trip
/// ends) rather than on every 3s poll tick.
final tripParticipantsProvider =
    FutureProvider.autoDispose.family<TripParticipants, String>((ref, id) {
  ref.watch(tripStreamProvider(id).select((v) => v.value?.status));
  return ref.read(rideRepositoryProvider).participants(id);
}, retry: shortNetworkRetry);

/// Human label for a trip's destination, for the in-trip status body
/// ("arriving at …" / "on the way to …"). The dest point never changes
/// mid-trip, so this only ever fetches once per trip (cached process-wide
/// besides — see `reverseGeocodeCached`).
final tripDestLabelProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, tripId) {
  final dest =
      ref.watch(tripStreamProvider(tripId).select((v) => v.value?.dest));
  if (dest == null) return Future.value(null);
  return reverseGeocodeCached(ref.watch(placesRepositoryProvider), dest);
}, retry: shortNetworkRetry);

/// Same as [tripDestLabelProvider] but for the pickup point — used on the
/// post-trip rating sheet, which wants both ends of the trip, not just
/// "where it's headed" the way the in-progress status body does.
final tripOriginLabelProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, tripId) {
  final origin =
      ref.watch(tripStreamProvider(tripId).select((v) => v.value?.origin));
  if (origin == null) return Future.value(null);
  return reverseGeocodeCached(ref.watch(placesRepositoryProvider), origin);
}, retry: shortNetworkRetry);

/// The signed-in user's own trips, newest first (Activity tab).
final myTripsProvider = FutureProvider.autoDispose<List<Trip>>((ref) {
  return ref.watch(rideRepositoryProvider).myTrips();
}, retry: shortNetworkRetry);

/// Infinite-scroll version of [myTripsProvider] for the Activity tab's
/// actual list rendering — [myTripsProvider] above stays as the small
/// cached/whole-list fetch other screens (e.g. the "ongoing ride" banner)
/// already depend on.
class TripsPaged extends PagedNotifier<Trip> {
  @override
  Future<List<Trip>> fetchPage(int offset, int limit) => ref
      .read(rideRepositoryProvider)
      .myTripsPage(limit: limit, offset: offset);
}

final myTripsPagedProvider =
    AsyncNotifierProvider.autoDispose<TripsPaged, PagedState<Trip>>(
        TripsPaged.new);

/// The signed-in rider's lifetime ride stats (My Stats screen).
final riderStatsProvider = FutureProvider.autoDispose<RiderStats>((ref) {
  return ref.watch(rideRepositoryProvider).myStats();
}, retry: shortNetworkRetry);

/// The signed-in driver's progress toward any live daily ride goal.
final driverTodayGoalsProvider = FutureProvider.autoDispose<DriverGoals>((ref) {
  return ref.watch(rideRepositoryProvider).todayGoals();
}, retry: shortNetworkRetry);

/// The signed-in driver's own earnings, bucketed by day/week/month (My
/// Stats, driver mode). Keyed by period string so switching the segmented
/// control between Day/Week/Month is just watching a different family
/// member — no manual refetch/loading-state juggling needed.
final driverEarningsProvider =
    FutureProvider.autoDispose.family<DriverEarnings, String>((ref, period) {
  return ref.watch(rideRepositoryProvider).driverEarnings(period);
}, retry: shortNetworkRetry);

/// Polls live bids for a bid-mode trip. Stops on its own once the trip
/// leaves 'requested' (accepted/cancelled) — no point polling a resolved
/// auction — mirroring `tripStreamProvider`'s own stop condition.
final tripBidsProvider =
    StreamProvider.autoDispose.family<List<Bid>, String>((ref, tripId) async* {
  final repo = ref.watch(rideRepositoryProvider);
  while (true) {
    final trip = ref.read(tripStreamProvider(tripId)).value;
    if (trip != null && trip.status != TripStatus.requested) {
      yield const [];
      return;
    }
    try {
      yield await repo.bids(tripId);
    } catch (_) {
      yield const [];
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});
