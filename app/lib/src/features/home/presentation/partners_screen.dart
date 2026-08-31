import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/paginated_list_view.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/partners_repository.dart';

/// Full list of operating/business partners — a real paginated fetch
/// against `GET /v1/partners` (see `partners_repository.dart`), infinite-
/// scrolled the same way the Activity tab and notifications screen are.
/// Split out of the About screen (which used to embed every partner's card
/// inline) so the list scrolls on its own instead of growing About without
/// bound as partners are added.
class PartnersScreen extends ConsumerWidget {
  const PartnersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final state = ref.watch(partnersPagedProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.partnersSection)),
      body: state.when(
        loading: () => const SkeletonList(padding: EdgeInsets.all(16)),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(partnersPagedProvider),
        ),
        data: (page) {
          if (page.items.isEmpty) {
            return Center(
              child: Text(l.partnersEmpty,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.outline)),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.read(partnersPagedProvider.notifier).refresh(),
            child: PaginatedListView<Partner>(
              state: page,
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
              onLoadMore: () =>
                  ref.read(partnersPagedProvider.notifier).loadMore(),
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, partner, i) =>
                  _PartnerCard(partner: partner),
            ),
          );
        },
      ),
    );
  }
}

class _PartnerCard extends StatelessWidget {
  const _PartnerCard({required this.partner});
  final Partner partner;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(partner.name,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            if (partner.panVat != null)
              _PartnerRow(label: l.partnerPanVat, value: partner.panVat!),
            if (partner.city != null)
              _PartnerRow(label: l.partnerAddress, value: partner.city!),
            if (partner.contactPhone != null)
              _PartnerRow(
                  label: l.partnerContact, value: partner.contactPhone!),
          ],
        ),
      ),
    );
  }
}

class _PartnerRow extends StatelessWidget {
  const _PartnerRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.outline)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
