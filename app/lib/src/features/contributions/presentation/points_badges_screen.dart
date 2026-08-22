import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/contributions_repository.dart';
import '../domain/models.dart';

class PointsBadgesScreen extends ConsumerStatefulWidget {
  const PointsBadgesScreen({super.key});

  @override
  ConsumerState<PointsBadgesScreen> createState() => _PointsBadgesScreenState();
}

class _PointsBadgesScreenState extends ConsumerState<PointsBadgesScreen> {
  bool _redeeming = false;

  Future<void> _redeem(PointsSummary summary) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.redeemPointsConfirmTitle),
        content: Text(l.redeemPointsConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.redeemPoints),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _redeeming = true);
    try {
      await ref.read(contributionsRepositoryProvider).redeem(summary.balance);
      Haptics.success();
      ref.invalidate(pointsSummaryProvider);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.redeemSuccess)));
      }
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.isNetwork ? l.errorNetwork : e.message)),
        );
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final async = ref.watch(pointsSummaryProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.myPointsBadges)),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(pointsSummaryProvider),
        ),
        data: (summary) {
          final canRedeem = summary.balance >= summary.minRedeemPoints;
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(pointsSummaryProvider),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.pointsBalance,
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 4),
                        Text(
                          '${summary.balance}',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(l.pointsBalanceBody,
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: !canRedeem || _redeeming
                              ? null
                              : () => _redeem(summary),
                          icon: _redeeming
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.redeem_rounded),
                          label: Text(l.redeemPoints),
                        ),
                        if (!canRedeem) ...[
                          const SizedBox(height: 6),
                          Text(
                            l.redeemPointsBelowMin(summary.minRedeemPoints),
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(l.badgesEarned,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (summary.badges.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text(l.noBadgesYet)),
                  )
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final b in summary.badges) _BadgeChip(badge: b),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({required this.badge});
  final ContributorBadge badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 96,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.military_tech_rounded, color: scheme.onTertiaryContainer, size: 28),
          const SizedBox(height: 8),
          Text(
            badge.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}
