import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../auth/application/auth_controller.dart';
import '../../places/data/places_repository.dart';
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
        const _RecentDropoffs(),
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
        const _PromoBanner(),
        const SizedBox(height: 16),
        const _InfoSlider(),
        const SizedBox(height: 20),
        if (!isDriver) const _BecomeDriverCard(),
        const SizedBox(height: 12),
        const _BecomeMerchantCard(),
      ],
    );
  }
}

/// Recent drop-offs under the search bar (Yango/Pathao style); tap to re-book.
class _RecentDropoffs extends ConsumerWidget {
  const _RecentDropoffs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentSearchesProvider).valueOrNull ?? const [];
    if (recent.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 4),
        for (final h in recent.take(3))
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: CircleAvatar(
              radius: 18,
              backgroundColor: scheme.surfaceContainerHighest,
              child: Icon(Icons.history_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
            ),
            title: Text(h.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: h.address.isEmpty
                ? null
                : Text(h.address,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => context.push(Routes.whereTo, extra: h),
          ),
      ],
    );
  }
}

/// Branded launch-offer banner (can be wired to campaigns later).
class _PromoBanner extends StatelessWidget {
  const _PromoBanner();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.promoTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l.promoBody,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.local_offer_rounded, color: Colors.white, size: 44),
        ],
      ),
    );
  }
}

/// Auto-advancing info carousel (safety / help / referrals).
class _InfoSlider extends StatefulWidget {
  const _InfoSlider();

  @override
  State<_InfoSlider> createState() => _InfoSliderState();
}

class _InfoSliderState extends State<_InfoSlider> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final cards = <_InfoData>[
      _InfoData(Icons.shield_rounded, l.infoSafetyTitle, l.infoSafetyBody,
          const [Color(0xFF2E7D32), Color(0xFF66BB6A)]),
      _InfoData(Icons.support_agent_rounded, l.infoHelpTitle, l.infoHelpBody,
          const [Color(0xFF1565C0), Color(0xFF42A5F5)]),
      _InfoData(Icons.card_giftcard_rounded, l.infoReferTitle, l.infoReferBody,
          const [Color(0xFF6A1B9A), Color(0xFFAB47BC)]),
    ];
    return Column(
      children: [
        SizedBox(
          height: 116,
          child: PageView.builder(
            controller: _controller,
            itemCount: cards.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => _InfoCard(data: cards[i]),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < cards.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: _page == i ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _page == i
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _InfoData {
  const _InfoData(this.icon, this.title, this.body, this.colors);
  final IconData icon;
  final String title;
  final String body;
  final List<Color> colors;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.data});
  final _InfoData data;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          colors: data.colors,
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      child: Row(
        children: [
          Icon(data.icon, color: Colors.white, size: 40),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  data.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
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
