import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/contributions_repository.dart';
import '../domain/models.dart';
import 'contribute_screen.dart';

class MyContributionsScreen extends ConsumerWidget {
  const MyContributionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(myContributionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.myContributions),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt_rounded),
            onPressed: () async {
              final ok = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const ContributeScreen()),
              );
              if (ok == true) ref.invalidate(myContributionsProvider);
            },
          ),
        ],
      ),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(myContributionsProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return Center(child: Text(l.noContributionsYet));
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(myContributionsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _ContributionTile(item: items[i]),
            ),
          );
        },
      ),
    );
  }
}

class _ContributionTile extends StatelessWidget {
  const _ContributionTile({required this.item});
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
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: item.status == 'rejected' && item.rejectionReason != null
          ? Text(item.rejectionReason!,
              maxLines: 2, overflow: TextOverflow.ellipsis)
          : null,
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
    );
  }
}
