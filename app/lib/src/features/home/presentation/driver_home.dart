import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/foreground/driver_foreground_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/request_ring.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/fare_stepper.dart';
import '../../../shared/widgets/swipe_to_confirm.dart';
import '../../driver/application/driver_controller.dart';
import '../../driver/data/driver_kyc_repository.dart';
import '../../driver/data/driver_repository.dart';
import '../../driver/domain/models.dart';
import '../../../shared/geocode_cache.dart';
import '../../places/data/places_repository.dart';
import '../../ride/application/ride_controller.dart';
import '../../ride/domain/models.dart' show DriverGoal, Trip, TripStatus;
import '../../ride/presentation/widgets/map_view.dart';
import '../../ride/presentation/widgets/search_radar.dart';

/// Driver home: one big online/offline control (presence heartbeat runs while
/// online) and incoming job offers with transparent net earnings. Gated on KYC
/// approval — the backend only lets approved drivers go online.
class DriverHome extends ConsumerWidget {
  const DriverHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final kyc = ref.watch(driverKycProvider);

    return kyc.when(
      // An approved, already-riding driver is the overwhelmingly common case
      // once this screen is actually being watched day to day, so the
      // online-board shape is the better bet here than a spinner — the
      // (rarer, effectively one-time) pending-KYC case briefly gets the
      // wrong skeleton shape instead, which is the cheaper mismatch to
      // accept of the two.
      loading: () => const DriverHomeSkeleton(),
      error: (_, __) => ErrorRetry(
        message: l.errorNetwork,
        onRetry: () => ref.invalidate(driverKycProvider),
      ),
      data: (data) {
        if (data.status != KycStatus.approved) {
          return _KycGate(status: data.status);
        }
        return const _OnlineBoard();
      },
    );
  }
}

/// Matches [_OnlineBoard]'s shape — the tall online/offline toggle card,
/// then the goal card — instead of a plain spinner or list-tile rows.
class DriverHomeSkeleton extends StatelessWidget {
  const DriverHomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Container(
          height: 208,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          height: 84,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ],
    );
  }
}

class _KycGate extends StatelessWidget {
  const _KycGate({required this.status});
  final KycStatus status;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.badge_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              status == KycStatus.rejected ? l.kycRejected : l.kycUnderReview,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(l.kycUnderReviewBody, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => context.push(Routes.kyc),
              child: Text(l.uploadDocuments),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnlineBoard extends ConsumerWidget {
  const _OnlineBoard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final status = ref.watch(driverControllerProvider);
    final offers = ref.watch(driverOffersProvider).valueOrNull ?? const [];
    final activeTrip = ref.watch(driverActiveTripProvider).valueOrNull;

    // A trip won by bid has no local "I just tapped accept" moment to
    // navigate on (the rider accepted the driver's bid, not the other way
    // round) — this is what catches it and sends the driver straight to the
    // trip screen instead of leaving them stranded on the idle board until
    // they notice the notification. An instant-accept offer already
    // navigates itself (see `_OfferCard`), so this only ever fires for the
    // bid case in practice, but it's a harmless no-op either way.
    ref.listen(driverActiveTripProvider, (prev, next) {
      final trip = next.valueOrNull;
      if (trip == null) return;
      // Deferred to the next frame in full, not called straight from this
      // listener — `ref.listen` can fire mid-build (e.g. right as
      // `driverControllerProvider` flips to online, in the same pass that
      // produces this rebuild), and touching `ref`/`context` — including
      // `ref.read`/state-writes, not just `context.go` — while a build is
      // still in progress, or while this widget is mid-`deactivate()`, is
      // exactly what corrupts the element tree. Reproduced live as both a
      // `_dependents.isEmpty` crash (going online with a trip already
      // waiting) and a "Looking up a deactivated widget's ancestor is
      // unsafe" crash (an earlier, narrower version of this fix that only
      // guarded the `context.go` call, not the reads above it, still hit
      // this). `context.mounted` alone doesn't catch it either — it stays
      // true through `deactivate()`; the check only becomes meaningful once
      // deferred past this frame, when Flutter has resolved deactivation to
      // either fully disposed or reactivated.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        // Keyed off `lastAutoNavigatedTripProvider`, not the previous poll
        // value — the latter resets to null every time this widget remounts
        // (e.g. the driver backs out of the trip screen to home), which
        // would re-fire the push for the very same, still-accepted trip in
        // a loop.
        final already = ref.read(lastAutoNavigatedTripProvider);
        if (trip.id == already) return;
        ref.read(lastAutoNavigatedTripProvider.notifier).state = trip.id;
        // `context.go`, not `context.push` — TripScreen's own PopScope
        // assumes it was reached this way (replacing the stack, nothing
        // underneath for back to reveal), and the driver should stay locked
        // into it until the trip actually finishes, not be able to swipe/
        // back their way to a home screen that still shows a job they
        // haven't dealt with.
        context.go('${Routes.trip}/${trip.id}');
      });
    });

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (activeTrip != null) _DriverActiveTripCard(trip: activeTrip),
        _OnlineCard(
          online: status.online,
          busy: status.busy,
          onToggle: () async {
            Haptics.success();
            try {
              await ref.read(driverControllerProvider.notifier).toggleOnline();
            } on LocationUnavailableException {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l.goOnlineNeedsLocation)),
              );
            } catch (_) {
              // Other failures (network, backend rejection) already update
              // `status` themselves; nothing extra to show here.
            }
          },
        ),
        const _TodayGoalCard(),
        const SizedBox(height: 16),
        if (status.online && offers.isEmpty)
          _IdleRadar(center: status.lastLocation, body: l.onlineBody),
        for (final offer in offers) _OfferCard(offer: offer),
      ],
    );
  }
}

/// Resume-into-the-trip card — the driver's counterpart to rider_home's own
/// `_ActiveTripCard`. Tapping the trip screen's back arrow deliberately just
/// navigates here (an assigned trip isn't cancelled by backing out of its
/// screen — see `_leaveTrip`), but that left the driver stranded on the
/// idle board with no way back to a trip they still need to complete short
/// of waiting for [driverActiveTripProvider]'s poll to auto-redirect them
/// again. This gives them an immediate, explicit way back.
class _DriverActiveTripCard extends ConsumerWidget {
  const _DriverActiveTripCard({required this.trip});
  final Trip trip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final routingToPickup = trip.status == TripStatus.accepted ||
        trip.status == TripStatus.arriving;
    final label = routingToPickup
        ? (ref.watch(tripOriginLabelProvider(trip.id)).valueOrNull)
        : (ref.watch(tripDestLabelProvider(trip.id)).valueOrNull);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: scheme.primaryContainer,
        child: ListTile(
          contentPadding: const EdgeInsets.all(12),
          leading: CircleAvatar(
            backgroundColor: scheme.primary,
            child: Icon(Icons.directions_car_rounded, color: scheme.onPrimary),
          ),
          title: Text(
            label ?? l.ongoingRide,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
          subtitle: Text(
            routingToPickup ? l.statusArriving : l.statusOnTrip,
            style: TextStyle(color: scheme.onPrimaryContainer),
          ),
          trailing: Icon(Icons.chevron_right_rounded,
              color: scheme.onPrimaryContainer),
          onTap: () => context.go('${Routes.trip}/${trip.id}'),
        ),
      ),
    );
  }
}

class _OnlineCard extends StatelessWidget {
  const _OnlineCard(
      {required this.online, required this.busy, required this.onToggle});

  final bool online;
  final bool busy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final statusContainer = online
        ? (dark ? Colors.green.shade900 : Colors.green.shade50)
        : (dark ? Colors.red.shade900 : Colors.red.shade50);
    final onStatusContainer = online
        ? (dark ? Colors.green.shade100 : Colors.green.shade900)
        : (dark ? Colors.red.shade100 : Colors.red.shade900);
    return Card(
      color: statusContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  online ? Icons.bolt_rounded : Icons.bolt_outlined,
                  color: onStatusContainer,
                ),
                const SizedBox(width: 8),
                Text(
                  online ? l.youAreOnline : l.youAreOffline,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: onStatusContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              online ? l.onlineBody : l.offlineBody,
              style: TextStyle(color: onStatusContainer),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : onToggle,
              style: FilledButton.styleFrom(
                backgroundColor: online
                    ? Colors.red.shade600
                    : (dark ? Colors.green.shade400 : Colors.green.shade600),
                foregroundColor: Colors.white,
              ),
              child: busy
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : Text(online ? l.goOffline : l.goOnline),
            ),
            TextButton.icon(
              onPressed: () async {
                await DriverForegroundService.requestBatteryExclusion();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.batteryExclusionDone)),
                  );
                }
              },
              icon: const Icon(Icons.battery_saver_rounded, size: 18),
              label: Text(l.batteryExclusion),
            ),
          ],
        ),
      ),
    );
  }
}

/// Progress toward any live "complete N rides today" campaign — purely
/// informational (the bonus is granted automatically server-side the
/// moment the threshold trip completes); hidden entirely when no such
/// campaign is currently active, same "don't show an empty state" pattern
/// `_ActiveTripCard`/`_PendingReviewsPrompt` use on the rider side.
class _TodayGoalCard extends ConsumerWidget {
  const _TodayGoalCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(driverTodayGoalsProvider).valueOrNull;
    if (goals == null || goals.goals.isEmpty) return const SizedBox.shrink();
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        children: [
          for (final goal in goals.goals)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                color: goal.achieved ? scheme.primaryContainer : null,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            goal.achieved
                                ? Icons.check_circle_rounded
                                : Icons.flag_rounded,
                            color: goal.achieved
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              goal.title,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: goal.target == 0
                              ? 0
                              : (goals.ridesToday / goal.target).clamp(0, 1),
                          minHeight: 8,
                          backgroundColor: scheme.surfaceContainerHighest,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        goal.achieved
                            ? l.driverGoalAchieved(_rewardLabel(goal))
                            : l.driverGoalProgress(goals.ridesToday,
                                goal.target, _rewardLabel(goal)),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _rewardLabel(DriverGoal goal) => goal.rewardKind == 'percent'
      ? '${goal.rewardValue.toStringAsFixed(0)}%'
      : 'NPR ${goal.rewardValue.toStringAsFixed(0)}';
}

/// Replaces the old bare spinner: a live map centered on the driver's own
/// position, with a distinct self-pin and the radar rings pulsing outward
/// from it — "we're scanning your area for jobs", the mirror image of the
/// rider's "we're scanning for drivers near you". No route or trip pins
/// (there's no trip yet); the wandering nearby-driver dots from the rider
/// framing are intentionally ignored here for the same reason.
class _IdleRadar extends StatelessWidget {
  const _IdleRadar({required this.center, required this.body});
  final LatLng? center;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (center == null) {
      // Momentary: only while the first GPS fix after going online is
      // still in flight.
      return Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Center(
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(body, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 320,
          child: Stack(
            children: [
              SearchRadar(
                origin: center!,
                builder: (context, _, circles) => MapView(
                  center: center!,
                  circles: circles,
                  pins: [
                    MapPin(center!, Icons.two_wheeler_rounded, scheme.primary)
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  color: scheme.surface.withValues(alpha: 0.9),
                  child: Text(body, textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfferCard extends ConsumerStatefulWidget {
  const _OfferCard({required this.offer});
  final DriverOffer offer;

  @override
  ConsumerState<_OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends ConsumerState<_OfferCard> {
  bool _busy = false;
  String? _pickupLabel;
  String? _destLabel;
  Timer? _tick;
  bool _bidSent = false;
  bool _showCounter = false;
  double? _counterAmount;

  @override
  void initState() {
    super.initState();
    _resolveLabels();
    // Redraws the countdown once a second; the offer disappears from the
    // list on its own once dispatch expires it server-side.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _resolveLabels() async {
    final repo = ref.read(placesRepositoryProvider);
    _pickupLabel = await reverseGeocodeCached(repo, widget.offer.origin);
    _destLabel = await reverseGeocodeCached(repo, widget.offer.dest);
    if (mounted) setState(() {});
  }

  Future<void> _accept() async {
    if (_expired) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).offerExpired)),
      );
      return;
    }
    setState(() => _busy = true);
    RequestRing.stop();
    final repo = ref.read(driverRepositoryProvider);
    try {
      await repo.accept(widget.offer.tripId);
      Haptics.success();
      if (mounted) context.push('${Routes.trip}/${widget.offer.tripId}');
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                e.isNetwork ? AppL10n.of(context).errorNetwork : e.message)));
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _placeBid(double amount) async {
    if (_expired) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).offerExpired)),
      );
      return;
    }
    setState(() => _busy = true);
    RequestRing.stop();
    final repo = ref.read(driverRepositoryProvider);
    try {
      await repo.placeBid(widget.offer.tripId, amount);
      Haptics.success();
      if (mounted) setState(() => _bidSent = true);
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                e.isNetwork ? AppL10n.of(context).errorNetwork : e.message)));
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decline() async {
    Haptics.warning();
    final repo = ref.read(driverRepositoryProvider);
    try {
      await repo.decline(widget.offer.tripId);
    } catch (_) {
      // Best-effort — the offer will lapse on its own TTL either way.
    }
  }

  String? _expiryLabel() {
    final expiresAt = widget.offer.expiresAt;
    if (expiresAt == null) return null;
    final left = expiresAt.difference(DateTime.now()).inSeconds;
    if (left <= 0) return null;
    return '${left}s';
  }

  // A zero/missing askFare would otherwise make the counter-offer stepper's
  // min == max == 0, permanently disabling both its buttons — same
  // degenerate-range bug as the rider-side bidding sheet.
  double _counterFloor(double? askFare) =>
      (askFare ?? 0) > 0 ? askFare! : 100.0;

  bool get _expired {
    final expiresAt = widget.offer.expiresAt;
    return expiresAt != null && !expiresAt.isAfter(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final offer = widget.offer;
    final expiry = _expiryLabel();
    // Previously nothing stopped a tap landing in the same frame the
    // countdown hits zero — the request just went out against an offer the
    // backend had already expired/reassigned, surfacing as a generic
    // network/error snackbar instead of a clear "offer expired" message.
    final expired = _expired;
    // How long until this driver could actually reach the pickup point —
    // previously the offer card only showed the trip's own origin→dest
    // distance, nothing about how far *this driver* is from pickup, which
    // is what actually matters for deciding whether to accept.
    final driverLoc = ref.watch(driverControllerProvider).lastLocation;
    final pickupEta = driverLoc == null
        ? null
        : ref.watch(tripEtaProvider(EtaQuery(driverLoc, offer.origin))).valueOrNull;
    final pickupEtaMins = pickupEta?.durationMins;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  offer.vehicleClass == 'four_wheeler'
                      ? Icons.directions_car_rounded
                      : Icons.two_wheeler_rounded,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.newJobOffer,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (expiry != null)
                  Text(
                    expiry,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _RoutePoint(
              icon: Icons.emoji_people_rounded,
              label: _pickupLabel ?? '…',
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 6),
            _RoutePoint(
              icon: Icons.sports_score_rounded,
              label: _destLabel ?? '…',
              color: Theme.of(context).colorScheme.secondary,
            ),
            if (offer.distanceKm != null || pickupEtaMins != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  if (offer.distanceKm != null)
                    Text(
                      '${offer.distanceKm!.toStringAsFixed(1)} km',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  if (offer.distanceKm != null && pickupEtaMins != null)
                    Text(' · ',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  // Distinct from `offer.distanceKm` above (the trip's own
                  // origin→dest distance) — this is how far *this driver*
                  // is from the pickup point right now, previously shown
                  // nowhere on the offer card at all.
                  if (pickupEtaMins != null)
                    Text(
                      l.etaArriving(pickupEtaMins),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            if (offer.isBidding) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l.ridersOffer),
                  Text(
                    'NPR ${(offer.askFare ?? 0).toStringAsFixed(0)}',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_bidSent)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Center(
                    child: Text(
                      l.bidSentWaiting,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              else if (_showCounter) ...[
                FareStepper(
                  amount: _counterAmount ?? _counterFloor(offer.askFare),
                  min: _counterFloor(offer.askFare),
                  // Matches the backend's own BID_COUNTER_MAX_RATIO (still
                  // clamped there to the legal per-km ceiling regardless of
                  // this client-side max) — keep the two in sync.
                  max: _counterFloor(offer.askFare) * 2.0,
                  onChanged: (v) => setState(() => _counterAmount = v),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _showCounter = false),
                      child: Text(l.decline),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy || expired
                            ? null
                            : () => _placeBid(
                                _counterAmount ?? (offer.askFare ?? 0)),
                        child: Text(l.submitCounter),
                      ),
                    ),
                  ],
                ),
              ] else
                Column(
                  children: [
                    // Three controls (decline/counter/swipe-accept) crammed
                    // into one Row left the swipe control too narrow to
                    // read or use at longer locale text lengths (confirmed
                    // live in Nepali: the counter-offer button pushed the
                    // swipe control's own label behind its thumb) — decline
                    // and counter-offer get their own row now so the swipe
                    // control always gets the full width it needs.
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: _busy ? null : _decline,
                            child: Text(l.decline),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _busy || expired
                                ? null
                                : () => setState(() => _showCounter = true),
                            child: Text(l.counterOffer),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SwipeToConfirm(
                      label: l.accept,
                      busy: _busy || expired,
                      onConfirmed: () =>
                          _placeBid(offer.askFare ?? offer.finalFare),
                    ),
                  ],
                ),
            ] else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(l.netEarning),
                  Text(
                    'NPR ${offer.netEarning.toStringAsFixed(0)}',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: _busy ? null : _decline,
                    child: Text(l.decline),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SwipeToConfirm(
                      label: l.accept,
                      busy: _busy || expired,
                      onConfirmed: _accept,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RoutePoint extends StatelessWidget {
  const _RoutePoint(
      {required this.icon, required this.label, required this.color});
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
