import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/contributions_repository.dart';
import '../domain/models.dart';

/// Landing screen for the places-contribution program: balance + redeem,
/// a short "how it works" pitch, the one action that matters (add a place),
/// a badge shelf, and a preview of recent submissions. Replaces three
/// disconnected drawer entries (submit / history / points) with one screen —
/// [ContributeScreen] and [MyContributionsScreen] still exist underneath,
/// reached from here via "Add a new place" and "See all".
class ContributeHubScreen extends ConsumerStatefulWidget {
  const ContributeHubScreen({super.key});

  @override
  ConsumerState<ContributeHubScreen> createState() =>
      _ContributeHubScreenState();
}

class _ContributeHubScreenState extends ConsumerState<ContributeHubScreen> {
  bool _redeeming = false;

  Future<void> _addPlace() async {
    final ok = await context.push<bool>(Routes.contribute);
    if (ok == true) {
      ref.invalidate(myContributionsProvider);
      ref.invalidate(pointsSummaryProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).contributionSubmitted)),
        );
      }
    }
  }

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

  void _seeAllHistory() => context.push(Routes.myContributions);

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final summaryAsync = ref.watch(pointsSummaryProvider);
    final contributionsAsync = ref.watch(myContributionsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.placesHubTitle)),
      body: summaryAsync.when(
        loading: () => const _HubSkeleton(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(pointsSummaryProvider),
        ),
        data: (summary) {
          final canRedeem = summary.balance >= summary.minRedeemPoints;
          final recent = contributionsAsync.value?.take(3).toList() ??
              const <PlaceContribution>[];

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(pointsSummaryProvider);
              ref.invalidate(myContributionsProvider);
            },
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
              children: [
                _HeroCard(
                  summary: summary,
                  canRedeem: canRedeem,
                  redeeming: _redeeming,
                  onRedeem: () => _redeem(summary),
                ),
                const SizedBox(height: 22),
                Text(l.howItWorks,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: .3,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                _StepRow(
                  number: 1,
                  title: l.earnStep1Title,
                  body: l.earnStep1Body,
                ),
                _StepRow(
                  number: 2,
                  title: l.earnStep2Title,
                  body: l.earnStep2Body,
                ),
                _StepRow(
                  number: 3,
                  title: l.earnStep3Title,
                  body: l.earnStep3Body,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _addPlace,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: Theme.of(context).colorScheme.onSurface,
                  ),
                  icon: const Icon(Icons.add_location_alt_rounded),
                  label: Text(l.addNewPlace),
                ),
                const SizedBox(height: 24),
                Text(l.badgesEarned,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (summary.badges.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(l.noBadgesYet,
                        style: Theme.of(context).textTheme.bodySmall),
                  )
                else
                  SizedBox(
                    height: 92,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: summary.badges.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (_, i) =>
                          _BadgeChip(badge: summary.badges[i]),
                    ),
                  ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.recentSubmissions,
                        style: Theme.of(context)
                            .textTheme
                            .labelLarge
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    TextButton(
                      onPressed: _seeAllHistory,
                      child: Text(l.seeAll),
                    ),
                  ],
                ),
                if (recent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(l.noContributionsYet,
                        style: Theme.of(context).textTheme.bodySmall),
                  )
                else
                  for (final item in recent) _RecentTile(item: item),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.summary,
    required this.canRedeem,
    required this.redeeming,
    required this.onRedeem,
  });

  final PointsSummary summary;
  final bool canRedeem;
  final bool redeeming;
  final VoidCallback onRedeem;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final npr = summary.balance * summary.pointsToNprRate;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.primaryContainer],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.pointsBalance.toUpperCase(),
            style: TextStyle(
              color: scheme.onPrimary.withValues(alpha: .85),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: .8,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${summary.balance}',
                style: TextStyle(
                  color: scheme.onPrimary,
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l.nprEquivalent(npr),
            style: TextStyle(
              color: scheme.onPrimary.withValues(alpha: .92),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: !canRedeem || redeeming ? null : onRedeem,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.onPrimary,
                foregroundColor: scheme.primary,
              ),
              child: redeeming
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : Text(l.redeemPoints),
            ),
          ),
          if (!canRedeem) ...[
            const SizedBox(height: 6),
            Text(
              l.redeemPointsBelowMin(summary.minRedeemPoints),
              style: TextStyle(
                color: scheme.onPrimary.withValues(alpha: .85),
                fontSize: 11.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow(
      {required this.number, required this.title, required this.body});
  final int number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '$number',
              style: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 2),
                Text(body,
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
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
      width: 84,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.military_tech_rounded,
              color: scheme.onTertiaryContainer, size: 26),
          const SizedBox(height: 6),
          Text(
            badge.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentTile extends StatelessWidget {
  const _RecentTile({required this.item});
  final PlaceContribution item;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (item.status) {
      'approved' => (
          l.contributionStatusApproved,
          scheme.primary,
          Icons.check_circle_rounded
        ),
      'rejected' => (
          l.contributionStatusRejected,
          scheme.error,
          Icons.cancel_rounded
        ),
      _ => (
          l.contributionStatusPending,
          scheme.outline,
          Icons.hourglass_top_rounded
        ),
    };
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            if (item.pointsAwarded != null)
              Text('+${item.pointsAwarded}',
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Matches the loaded screen's shape — a big gradient hero card, then the
/// "how it works" steps and badges rows — instead of generic list-tile rows.
class _HubSkeleton extends StatelessWidget {
  const _HubSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Container(
          height: 176,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        const SizedBox(height: 22),
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: SkeletonBox(width: double.infinity, height: 13),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ],
    );
  }
}
