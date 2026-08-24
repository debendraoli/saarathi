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
import '../../ride/domain/models.dart' show DriverGoal;
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
      loading: () => const LoadingView(),
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

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _OnlineCard(
          online: status.online,
          busy: status.busy,
          onToggle: () {
            Haptics.success();
            ref.read(driverControllerProvider.notifier).toggleOnline();
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

class _OnlineCard extends StatelessWidget {
  const _OnlineCard(
      {required this.online, required this.busy, required this.onToggle});

  final bool online;
  final bool busy;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: online ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  online ? Icons.bolt_rounded : Icons.bolt_outlined,
                  color: online ? scheme.onPrimaryContainer : scheme.outline,
                ),
                const SizedBox(width: 8),
                Text(
                  online ? l.youAreOnline : l.youAreOffline,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: online ? scheme.onPrimaryContainer : null,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              online ? l.onlineBody : l.offlineBody,
              style: TextStyle(
                color: online
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : onToggle,
              style: online
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
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
                              style: const TextStyle(fontWeight: FontWeight.w700),
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
                            : l.driverGoalProgress(
                                goals.ridesToday, goal.target, _rewardLabel(goal)),
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

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final offer = widget.offer;
    final expiry = _expiryLabel();
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
              icon: Icons.trip_origin,
              label: _pickupLabel ?? '…',
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 6),
            _RoutePoint(
              icon: Icons.location_on_rounded,
              label: _destLabel ?? '…',
              color: Theme.of(context).colorScheme.secondary,
            ),
            if (offer.distanceKm != null) ...[
              const SizedBox(height: 6),
              Text(
                '${offer.distanceKm!.toStringAsFixed(1)} km',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                  amount: _counterAmount ?? (offer.askFare ?? 0),
                  min: offer.askFare ?? 0,
                  max: (offer.askFare ?? 0) * 1.5,
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
                        onPressed: _busy
                            ? null
                            : () => _placeBid(
                                _counterAmount ?? (offer.askFare ?? 0)),
                        child: Text(l.submitCounter),
                      ),
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    TextButton(
                      onPressed: _busy ? null : _decline,
                      child: Text(l.decline),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _showCounter = true),
                      child: Text(l.counterOffer),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SwipeToConfirm(
                        label: l.accept,
                        busy: _busy,
                        onConfirmed: () =>
                            _placeBid(offer.askFare ?? offer.finalFare),
                      ),
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
                      busy: _busy,
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
