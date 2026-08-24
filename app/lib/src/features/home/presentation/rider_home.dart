import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../auth/application/auth_controller.dart';
import '../../campaigns/data/campaigns_repository.dart';
import '../../marketplace/data/marketplace_repository.dart';
import '../../merchant/data/merchant_repository.dart';
import '../../places/data/places_repository.dart';
import '../../places/presentation/address_search_screen.dart';
import '../../ride/application/ride_controller.dart';
import '../../ride/application/trip_ws.dart';
import '../../ride/domain/models.dart' show TripStatus;

/// Opens the address search; routes the pick into the ride flow (map picker or
/// a prefilled destination).
Future<void> openWhereTo(BuildContext context) async {
  final l = AppL10n.of(context);
  final pick = await Navigator.of(context).push<AddressPick>(
    MaterialPageRoute(
      builder: (_) => AddressSearchScreen(title: l.searchDestinationTitle),
    ),
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
    // The backend only allows one active *ride* per rider at a time (parcel
    // deliveries are a separate concern and aren't gated) — lock the ride-
    // booking entry points here too instead of letting the request round-trip
    // just to bounce off that guard with a confusing error.
    final trips = ref.watch(myTripsProvider).valueOrNull ?? const [];
    final hasActiveRide =
        trips.any((t) => t.isActive && t.tripType != 'delivery');

    void onWhereToTap() {
      if (hasActiveRide) {
        Haptics.tap();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.activeRideBlocksNew)),
        );
        return;
      }
      openWhereTo(context);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _ActiveTripCard(),
        const _PendingReviewsPrompt(),
        _WhereToCard(onTap: onWhereToTap, locked: hasActiveRide),
        if (!hasActiveRide) const _RecentDropoffs(),
        const SizedBox(height: 20),
        GridView.count(
          // Parcel moved out of this grid — it's promoted via the showcase
          // carousel below instead, and booked from the same pickup/
          // destination screen as a ride (see WhereToScreen's mode toggle).
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          children: [
            _Service(
              icon: Icons.two_wheeler_rounded,
              label: l.modeRider,
              onTap: onWhereToTap,
              locked: hasActiveRide,
            ),
            _Service(
              icon: Icons.restaurant_rounded,
              label: l.food,
              onTap: () => context.push(Routes.food),
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
        const SizedBox(height: 20),
        const _PromoBanner(),
        const SizedBox(height: 16),
        const _InfoSlider(),
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
                : Text(h.address, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => context.push(Routes.whereTo, extra: h),
          ),
      ],
    );
  }
}

/// Branded launch-offer banner — shows a real active campaign when one
/// exists (auto-applied at checkout, no code to enter), falling back to
/// the static launch copy when nothing's currently live so the card is
/// never empty.
class _PromoBanner extends ConsumerWidget {
  const _PromoBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final offer = ref.watch(activeOffersProvider).valueOrNull?.firstOrNull;
    final title = offer?.title ?? l.promoTitle;
    final body = offer?.discountLine ?? l.promoBody;

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => openWhereTo(context),
      child: Container(
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
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.local_offer_rounded, color: Colors.white, size: 44),
          ],
        ),
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
      _InfoData(
        Icons.inventory_2_rounded,
        l.parcelTitle,
        l.parcelShowcaseBody,
        const [Color(0xFFEF6C00), Color(0xFFFFA726)],
        onTap: () => context.push('${Routes.whereTo}?mode=delivery'),
      ),
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
  const _InfoData(this.icon, this.title, this.body, this.colors, {this.onTap});
  final IconData icon;
  final String title;
  final String body;
  final List<Color> colors;

  /// Only the parcel-delivery showcase slide is tappable today — the
  /// safety/help/refer slides are pure information, no destination to send
  /// them to.
  final VoidCallback? onTap;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.data});
  final _InfoData data;

  @override
  Widget build(BuildContext context) {
    final card = Container(
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
          if (data.onTap != null)
            const Icon(Icons.chevron_right_rounded, color: Colors.white70),
        ],
      ),
    );
    if (data.onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: data.onTap,
      child: card,
    );
  }
}

/// Surfaces the rider's in-progress ride, if any, so it's never "lost" behind
/// the normal request flow — and gives them a way back into it instead of
/// wondering whether it's still happening (the backend also refuses a new
/// ride request while one is active; this is the visible half of that rule).
class _ActiveTripCard extends ConsumerWidget {
  const _ActiveTripCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final trips = ref.watch(myTripsProvider).valueOrNull ?? const [];
    final active = trips.where((t) => t.isActive).firstOrNull;
    if (active == null) return const SizedBox.shrink();

    // Same live-preview data the full trip screen shows, so the resume card
    // is actually useful at a glance instead of a bare "tap to resume" line.
    final destLabel = ref.watch(tripDestLabelProvider(active.id)).valueOrNull;
    final driverLoc = ref.watch(tripLocationProvider(active.id)).valueOrNull;
    final routingToPickup = active.status == TripStatus.accepted ||
        active.status == TripStatus.arriving;
    String? etaText;
    if (driverLoc != null &&
        (routingToPickup || active.status == TripStatus.inProgress)) {
      final target = routingToPickup ? active.origin : active.dest;
      final eta =
          ref.watch(tripEtaProvider(EtaQuery(driverLoc, target))).valueOrNull;
      if (eta != null) {
        etaText = routingToPickup
            ? l.etaArriving(eta.durationMins)
            : l.etaToDestination(eta.durationMins);
      }
    }

    final scheme = Theme.of(context).colorScheme;
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
            destLabel ?? l.ongoingRide,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
          subtitle: Text(
            [
              'NPR ${active.finalFare.toStringAsFixed(2)}',
              if (etaText != null) etaText,
            ].join(' · '),
            style: TextStyle(color: scheme.onPrimaryContainer),
          ),
          trailing: Icon(Icons.chevron_right_rounded,
              color: scheme.onPrimaryContainer),
          onTap: () => context.push('${Routes.trip}/${active.id}'),
        ),
      ),
    );
  }
}

/// Set once a dialog has been shown so it doesn't reappear on every rebuild
/// of the home screen — reset naturally on app restart (session-scoped).
bool _pendingReviewsPromptShown = false;

/// Passive nudge to rate completed rides/deliveries: renders nothing itself,
/// just pops a one-time dialog (per app session) the first time it notices
/// something unrated, and links through to Activity to act on it.
class _PendingReviewsPrompt extends ConsumerStatefulWidget {
  const _PendingReviewsPrompt();

  @override
  ConsumerState<_PendingReviewsPrompt> createState() =>
      _PendingReviewsPromptState();
}

class _PendingReviewsPromptState extends ConsumerState<_PendingReviewsPrompt> {
  @override
  Widget build(BuildContext context) {
    final trips = ref.watch(myTripsProvider).valueOrNull ?? const [];
    final orders = ref.watch(myOrdersProvider).valueOrNull ?? const [];
    final pendingTrips =
        trips.where((t) => t.status == TripStatus.completed && !t.rated);
    final pendingOrders = orders
        .where((o) => o.status == 'delivered' && o.tripId != null && !o.rated);
    final count = pendingTrips.length + pendingOrders.length;

    if (count > 0 && !_pendingReviewsPromptShown) {
      _pendingReviewsPromptShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPrompt(count);
      });
    }
    return const SizedBox.shrink();
  }

  void _showPrompt(int count) {
    final l = AppL10n.of(context);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.pendingReviewsBanner(count)),
        content: Text(l.pendingReviewsPromptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.reviewsPromptLater),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push(Routes.activity);
            },
            child: Text(l.reviewsPromptGo),
          ),
        ],
      ),
    );
  }
}

class _WhereToCard extends StatelessWidget {
  const _WhereToCard({required this.onTap, this.locked = false});
  final VoidCallback onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: locked ? 0.6 : 1,
      child: Card(
        color: scheme.primaryContainer,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(locked ? Icons.lock_outline_rounded : Icons.search_rounded,
                    color: scheme.onPrimaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    locked ? l.activeRideBlocksNew : l.whereTo,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                          fontSize: locked ? 15 : null,
                        ),
                  ),
                ),
                if (!locked)
                  Icon(Icons.arrow_forward_rounded,
                      color: scheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Service extends StatelessWidget {
  const _Service({
    required this.icon,
    required this.label,
    this.onTap,
    this.locked = false,
  }) : soon = false;

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool locked;
  final bool soon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: soon || locked ? 0.5 : 1,
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

/// Hidden once the account already has a store registration (pending,
/// approved, or rejected-but-not-yet-resolved) — one registration owns
/// exactly one store, so there's no "apply again" path while one is on file.
class _BecomeMerchantCard extends ConsumerWidget {
  const _BecomeMerchantCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myMerchants = ref.watch(myMerchantsProvider).valueOrNull;
    if (myMerchants != null && myMerchants.any((m) => !m.isRejected)) {
      return const SizedBox.shrink();
    }
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: CircleAvatar(
          backgroundColor: scheme.tertiaryContainer,
          child:
              Icon(Icons.storefront_rounded, color: scheme.onTertiaryContainer),
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
