import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../auth/application/auth_controller.dart';
import '../../places/presentation/address_search_screen.dart';

/// Opens the address search; routes the pick into the ride flow (map picker or
/// a prefilled destination).
Future<void> openWhereTo(BuildContext context) async {
  final pick = await Navigator.of(context).push<AddressPick>(
    MaterialPageRoute(builder: (_) => const AddressSearchScreen()),
  );
  if (pick == null || !context.mounted) return;
  if (pick.chooseOnMap) {
    context.push(Routes.whereTo);
  } else if (pick.hit != null) {
    context.push(Routes.whereTo, extra: pick.hit);
  }
}

/// Rider home: a prominent "Where to?" entry into the ride flow, the service
/// grid (rides live; delivery verticals staged), and a become-a-driver nudge.
class RiderHome extends ConsumerWidget {
  const RiderHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final isDriver = ref.watch(authControllerProvider).user?.isDriver ?? false;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _WhereToCard(onTap: () => openWhereTo(context)),
        const SizedBox(height: 20),
        GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          children: [
            _Service(
              icon: Icons.two_wheeler_rounded,
              label: l.modeRider,
              onTap: () => openWhereTo(context),
            ),
            _Service(
              icon: Icons.restaurant_rounded,
              label: l.food,
              onTap: () => context.push(Routes.food),
            ),
            _Service(
              icon: Icons.inventory_2_rounded,
              label: 'Parcel',
              onTap: () => context.push(Routes.parcel),
            ),
            _Service(
              icon: Icons.local_grocery_store_rounded,
              label: l.grocery,
              onTap: () => context.push(Routes.grocery),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (!isDriver) const _BecomeDriverCard(),
        const SizedBox(height: 12),
        const _BecomeMerchantCard(),
      ],
    );
  }
}

class _WhereToCard extends StatelessWidget {
  const _WhereToCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.search_rounded, color: scheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l.whereTo,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Icon(Icons.arrow_forward_rounded,
                  color: scheme.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _Service extends StatelessWidget {
  const _Service({required this.icon, required this.label, this.onTap})
      : soon = false;

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool soon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: soon ? 0.5 : 1,
      child: InkWell(
        onTap: soon ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 56,
              width: 56,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

class _BecomeDriverCard extends ConsumerWidget {
  const _BecomeDriverCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          child: Icon(
            Icons.directions_car_rounded,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
        title: Text(
          l.becomeDriver,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(l.becomeDriverBody),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => context.push(Routes.becomeDriver),
      ),
    );
  }
}

class _BecomeMerchantCard extends StatelessWidget {
  const _BecomeMerchantCard();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: CircleAvatar(
          backgroundColor: scheme.tertiaryContainer,
          child: Icon(Icons.storefront_rounded,
              color: scheme.onTertiaryContainer),
        ),
        title: Text(l.becomeMerchant,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(l.becomeMerchantBody),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => context.push(Routes.merchantOnboarding),
      ),
    );
  }
}
