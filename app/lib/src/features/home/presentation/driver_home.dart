import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../../driver/application/driver_controller.dart';
import '../../driver/data/driver_kyc_repository.dart';
import '../../driver/domain/models.dart';
import '../../driver/data/driver_repository.dart';

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
            Icon(Icons.badge_rounded,
                size: 48, color: Theme.of(context).colorScheme.primary),
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
          onToggle: () => ref.read(driverControllerProvider.notifier).toggleOnline(),
        ),
        const SizedBox(height: 16),
        if (status.online && offers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Center(
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(l.onlineBody, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        for (final offer in offers) _OfferCard(offer: offer),
      ],
    );
  }
}

class _OnlineCard extends StatelessWidget {
  const _OnlineCard({required this.online, required this.busy, required this.onToggle});

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
                Icon(online ? Icons.bolt_rounded : Icons.bolt_outlined,
                    color: online ? scheme.onPrimaryContainer : scheme.outline),
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
            Text(online ? l.onlineBody : l.offlineBody,
                style: TextStyle(
                    color: online ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : onToggle,
              style: online
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error, foregroundColor: scheme.onError)
                  : null,
              child: busy
                  ? const SizedBox(
                      height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : Text(online ? l.goOffline : l.goOnline),
            ),
          ],
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

  Future<void> _act(bool accept) async {
    setState(() => _busy = true);
    final repo = ref.read(driverRepositoryProvider);
    try {
      if (accept) {
        await repo.accept(widget.offer.tripId);
        if (mounted) context.push('${Routes.trip}/${widget.offer.tripId}');
      } else {
        await repo.decline(widget.offer.tripId);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final offer = widget.offer;
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
                Text(l.newJobOffer,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
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
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _act(false),
                    child: Text(l.decline),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _busy ? null : () => _act(true),
                    child: _busy
                        ? const SizedBox(
                            height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.2))
                        : Text(l.accept),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
