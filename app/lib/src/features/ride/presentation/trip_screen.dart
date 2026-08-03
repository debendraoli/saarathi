import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/location.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../comms/application/call_controller.dart';
import '../../comms/presentation/call_screen.dart';
import '../../safety/presentation/qr_scan_screen.dart';
import '../application/ride_controller.dart';
import '../application/trip_ws.dart';
import '../data/ride_repository.dart';
import '../domain/models.dart';
import 'widgets/map_view.dart';
import 'widgets/rating_sheet.dart';

/// One screen for the whole live ride: searching → driver on the way → on trip →
/// completed. Status comes from polling; the driver pin from the trip WS.
class TripScreen extends ConsumerWidget {
  const TripScreen({super.key, required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final tripAsync = ref.watch(tripStreamProvider(tripId));
    final driverLoc = ref.watch(tripLocationProvider(tripId)).valueOrNull;

    return Scaffold(
      body: tripAsync.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(tripStreamProvider(tripId)),
        ),
        data: (trip) {
          final myId = ref.watch(authControllerProvider).user?.id;
          final iAmDriver = myId != null && myId == trip.driverId;
          final canComms = trip.driverId != null && trip.isActive;
          return Stack(
            children: [
              MapView(
                center: driverLoc ?? trip.origin,
                route: [trip.origin, trip.dest],
                pins: [
                  MapPin(
                    trip.origin,
                    Icons.trip_origin,
                    Theme.of(context).colorScheme.primary,
                  ),
                  MapPin(
                    trip.dest,
                    Icons.location_on_rounded,
                    Theme.of(context).colorScheme.secondary,
                  ),
                  if (driverLoc != null)
                    MapPin(
                      driverLoc,
                      Icons.navigation_rounded,
                      Theme.of(context).colorScheme.tertiary,
                    ),
                ],
              ),
              // Invisible: routes incoming calls to the call screen.
              _CallWatcher(tripId: tripId),
              // Invisible: the driver streams position during an active trip.
              if (iAmDriver && trip.isActive)
                _DriverLocationPublisher(tripId: tripId),
              SafeArea(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _MapCircleButton(
                          icon: Icons.arrow_back_rounded,
                          onTap: () => context.go(Routes.home),
                        ),
                        if (canComms) ...[
                          const SizedBox(height: 8),
                          _CommsBar(tripId: tripId, isRider: !iAmDriver),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SosButton(tripId: tripId),
                        const SizedBox(height: 8),
                        _ShareTripButton(tripId: tripId),
                      ],
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  child: _StatusSheet(trip: trip),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusSheet extends ConsumerWidget {
  const _StatusSheet({required this.trip});
  final Trip trip;

  (IconData, String, String) _display(AppL10n l) {
    switch (trip.status) {
      case TripStatus.searching:
      case TripStatus.requested:
        return (Icons.search_rounded, l.findingDriver, l.findingDriverBody);
      case TripStatus.accepted:
      case TripStatus.arriving:
        return (
          Icons.directions_car_rounded,
          l.driverAssigned,
          l.statusArriving
        );
      case TripStatus.inProgress:
        return (Icons.navigation_rounded, l.statusOnTrip, '');
      case TripStatus.completed:
        return (Icons.check_circle_rounded, l.statusCompleted, '');
      case TripStatus.noDriver:
        return (Icons.search_off_rounded, l.noDriverFound, l.noDriverFoundBody);
      default:
        return (Icons.info_outline_rounded, l.statusArriving, '');
    }
  }

  /// The driver's next forward transition + its button label, or null.
  (String, String)? _driverNext(AppL10n l) {
    switch (trip.status) {
      case TripStatus.accepted:
        return ('arriving', l.driverArrived);
      case TripStatus.arriving:
        return ('in_progress', l.startTrip);
      case TripStatus.inProgress:
        return ('completed', l.completeTrip);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final (icon, title, body) = _display(l);
    final searching = trip.status == TripStatus.searching ||
        trip.status == TripStatus.requested;
    final done = trip.status == TripStatus.completed ||
        trip.status == TripStatus.cancelled ||
        trip.status == TripStatus.noDriver;
    final myId = ref.watch(authControllerProvider).user?.id;
    final iAmDriver = myId != null && myId == trip.driverId;
    final driverNext = iAmDriver ? _driverNext(l) : null;

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(
                    icon,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (body.isNotEmpty)
                        Text(
                          body,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                    ],
                  ),
                ),
                if (searching)
                  const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
              ],
            ),
            if (driverNext != null) ...[
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () async {
                  await ref
                      .read(rideRepositoryProvider)
                      .updateStatus(trip.id, driverNext.$1);
                  ref.invalidate(tripStreamProvider(trip.id));
                },
                child: Text(driverNext.$2),
              ),
            ],
            if (searching) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  await ref.read(rideRepositoryProvider).cancel(trip.id);
                  if (context.mounted) context.go(Routes.home);
                },
                child: Text(l.cancelRide),
              ),
            ],
            if (done) ...[
              const SizedBox(height: 12),
              if (trip.status == TripStatus.completed)
                FilledButton.icon(
                  onPressed: () => _rate(context, ref, trip.id),
                  icon: const Icon(Icons.star_rounded),
                  label: Text(l.rateTrip),
                )
              else
                FilledButton(
                  onPressed: () => context.go(Routes.home),
                  child: Text(l.actionDone),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _rate(BuildContext context, WidgetRef ref, String tripId) async {
    final result = await showRatingSheet(context);
    if (result == null) return;
    try {
      await ref
          .read(rideRepositoryProvider)
          .rate(tripId, result.stars, comment: result.comment);
    } catch (_) {/* non-blocking */}
    if (context.mounted) context.go(Routes.home);
  }
}

/// Shares a `saarathi://trip/<id>` deep link so a trusted contact can follow
/// along. Opening it on a device with the app installed jumps to this trip.
class _ShareTripButton extends StatelessWidget {
  const _ShareTripButton({required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(
        tooltip: l.shareTrip,
        icon: const Icon(Icons.ios_share_rounded),
        onPressed: () {
          final link = 'saarathi://trip/$tripId';
          SharePlus.instance.share(
            ShareParams(
              text: '${l.shareTripMessage}\n$link',
              subject: l.shareTrip,
            ),
          );
        },
      ),
    );
  }
}

/// A round, elevated map overlay button (back, etc.).
class _MapCircleButton extends StatelessWidget {
  const _MapCircleButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: IconButton(icon: Icon(icon), onPressed: onTap),
    );
  }
}

class _SosButton extends ConsumerWidget {
  const _SosButton({required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return FloatingActionButton.extended(
      heroTag: 'sos',
      backgroundColor: Theme.of(context).colorScheme.error,
      foregroundColor: Theme.of(context).colorScheme.onError,
      icon: const Icon(Icons.emergency_share_rounded),
      label: Text(l.sos),
      onPressed: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(l.sos),
            content: Text(l.sosConfirm),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l.sos),
              ),
            ],
          ),
        );
        if (ok == true && context.mounted) {
          try {
            final here = await currentLatLng();
            await ref.read(rideRepositoryProvider).sos(
                  tripId,
                  lat: here.latitude,
                  lng: here.longitude,
                );
          } catch (_) {/* best effort */}
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Theme.of(context).colorScheme.error,
                content: Text(l.sosSent),
              ),
            );
          }
        }
      },
    );
  }
}

/// Chat / voice / video / (rider) QR-scan actions during an active trip.
class _CommsBar extends ConsumerWidget {
  const _CommsBar({required this.tripId, required this.isRider});
  final String tripId;
  final bool isRider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget btn(IconData icon, VoidCallback onTap) => Material(
          color: Theme.of(context).colorScheme.surface,
          shape: const CircleBorder(),
          elevation: 2,
          child: IconButton(icon: Icon(icon), onPressed: onTap),
        );

    return Column(
      children: [
        btn(Icons.chat_rounded, () => context.push(Routes.chat, extra: tripId)),
        const SizedBox(height: 8),
        btn(Icons.call_rounded, () {
          context.push(Routes.call,
              extra: CallArgs(tripId: tripId, asCaller: true));
        }),
        const SizedBox(height: 8),
        btn(Icons.videocam_rounded, () {
          context.push(
            Routes.call,
            extra: CallArgs(tripId: tripId, video: true, asCaller: true),
          );
        }),
        if (isRider) ...[
          const SizedBox(height: 8),
          btn(Icons.qr_code_scanner_rounded, () async {
            final code = await scanQr(context);
            if (code != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Verified: $code')),
              );
            }
          }),
        ],
      ],
    );
  }
}

/// Watches for an incoming WebRTC call and opens the call screen to answer.
class _CallWatcher extends ConsumerStatefulWidget {
  const _CallWatcher({required this.tripId});
  final String tripId;

  @override
  ConsumerState<_CallWatcher> createState() => _CallWatcherState();
}

class _CallWatcherState extends ConsumerState<_CallWatcher> {
  CallController? _controller;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(callControllerProvider(widget.tripId));
    _controller!.addListener(_check);
  }

  Future<void> _check() async {
    if (_open) return;
    if (_controller!.status == CallStatus.incoming) {
      _open = true;
      await context.push(
        Routes.call,
        extra: CallArgs(tripId: widget.tripId, asCaller: false),
      );
      _open = false;
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch to keep the call controller (and its signaling) alive.
    ref.watch(callControllerProvider(widget.tripId));
    return const SizedBox.shrink();
  }
}

/// While a driver is on an active trip, publish live position every few seconds.
class _DriverLocationPublisher extends ConsumerStatefulWidget {
  const _DriverLocationPublisher({required this.tripId});
  final String tripId;

  @override
  ConsumerState<_DriverLocationPublisher> createState() =>
      _DriverLocationPublisherState();
}

class _DriverLocationPublisherState
    extends ConsumerState<_DriverLocationPublisher> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ping();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _ping());
  }

  Future<void> _ping() async {
    try {
      final here = await currentLatLng();
      await ref
          .read(rideRepositoryProvider)
          .postLocation(widget.tripId, here.latitude, here.longitude);
    } catch (_) {/* skip a beat */}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
