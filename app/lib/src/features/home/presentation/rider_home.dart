import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../auth/application/auth_controller.dart';
import '../../campaigns/data/campaigns_repository.dart';
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
          // Slightly taller than square — the redesigned cards carry an
          // icon badge + label + subtitle now, not just an icon + label.
          childAspectRatio: 0.85,
          children: [
            _Service(
              icon: Icons.two_wheeler_rounded,
              label: l.modeRider,
              subtitle: l.serviceRideSubtitle,
              tint: _ServiceTint.ride,
              iconColor: _ServiceTint.rideIcon,
              onTap: onWhereToTap,
              locked: hasActiveRide,
            ),
            _Service(
              icon: Icons.restaurant_rounded,
              label: l.food,
              subtitle: l.serviceFoodSubtitle,
              tint: _ServiceTint.food,
              iconColor: _ServiceTint.foodIcon,
              onTap: () => context.push(Routes.food),
            ),
            _Service(
              icon: Icons.local_grocery_store_rounded,
              label: l.grocery,
              subtitle: l.serviceGrocerySubtitle,
              tint: _ServiceTint.grocery,
              iconColor: _ServiceTint.groceryIcon,
              onTap: () => context.push(Routes.grocery),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const _HomeCarousel(),
        const SizedBox(height: 16),
        const _EarnNudgeRow(),
      ],
    );
  }
}

/// Matches [RiderHome]'s actual shape — a search-bar card, a 3-across
/// service row, and a carousel placeholder — shown while `HomeShell` is
/// still working out whether this account gets Rider/Driver/Merchant home
/// (previously a generic list-tile skeleton, which looked nothing like any
/// of the three).
class RiderHomeSkeleton extends StatelessWidget {
  const RiderHomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Container(
          height: 76,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 108,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        Container(
          height: 104,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
        ),
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
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 8),
        itemCount: recent.take(3).length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final h = recent.take(3).toList()[i];
          return Material(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(13),
            child: InkWell(
              borderRadius: BorderRadius.circular(13),
              onTap: () => context.push(Routes.whereTo, extra: h),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5)),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_rounded,
                        size: 15, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 7),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        h.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One combined, auto-advancing carousel — a real active campaign (or the
/// static launch offer, so the slide is never empty) leads, followed by the
/// parcel/safety/help/refer showcase slides. Previously two separate
/// carousels stacked directly on top of each other doing the same visual
/// job twice; this is one paginated rail, same as Grab/Pathao's home promo
/// rail.
class _HomeCarousel extends ConsumerStatefulWidget {
  const _HomeCarousel();

  @override
  ConsumerState<_HomeCarousel> createState() => _HomeCarouselState();
}

class _HomeCarouselState extends ConsumerState<_HomeCarousel> {
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
    final scheme = Theme.of(context).colorScheme;
    final offer = ref.watch(activeOffersProvider).valueOrNull?.firstOrNull;
    final cards = <_InfoData>[
      _InfoData(
        Icons.local_offer_rounded,
        offer?.title ?? l.promoTitle,
        offer?.discountLine ?? l.promoBody,
        [scheme.primary, scheme.tertiary],
        onTap: () => openWhereTo(context),
      ),
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
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        elevation: 1.5,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    locked ? Icons.lock_outline_rounded : Icons.search_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: locked
                      ? Text(
                          l.activeRideBlocksNew,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.whereTo,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              l.whereToSubtitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                ),
                if (!locked)
                  Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Per-service accent colors for the home quick-action row — distinct hues
/// (not one shared grey) so Ride/Food/Grocery read as different things at a
/// glance, matching the tinted-icon treatment already used for the
/// marketplace's category rail and offer ribbons this same redesign pass.
class _ServiceTint {
  const _ServiceTint._();
  static const ride = Color(0xFFFEF3DF);
  static const rideIcon = Color(0xFFC9820F);
  static const food = Color(0xFFFDE8EC);
  static const foodIcon = Color(0xFFDC143C);
  static const grocery = Color(0xFFE4F5EA);
  static const groceryIcon = Color(0xFF1C8A4B);
}

class _Service extends StatelessWidget {
  const _Service({
    required this.icon,
    required this.label,
    required this.tint,
    required this.iconColor,
    this.subtitle,
    this.onTap,
    this.locked = false,
  }) : soon = false;

  final IconData icon;
  final String label;
  final String? subtitle;
  final Color tint;
  final Color iconColor;
  final VoidCallback? onTap;
  final bool locked;
  final bool soon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: soon || locked ? 0.5 : 1,
      child: Material(
        color: tint,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: soon ? null : onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 44,
                  width: 44,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: .16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: iconColor, size: 23),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Replaces the two full-width "become a driver" / "become a merchant"
/// cards with one slim row carrying whichever asks still apply — full width
/// competed visually with the primary "Where to?" search action above it,
/// which this demotes back to a quiet secondary nudge. Hidden entirely once
/// neither ask applies (already a driver *and* has a store on file).
class _EarnNudgeRow extends ConsumerWidget {
  const _EarnNudgeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isDriver = ref.watch(authControllerProvider).user?.isDriver ?? false;
    final myMerchants = ref.watch(myMerchantsProvider).valueOrNull;
    final hasMerchant =
        myMerchants != null && myMerchants.any((m) => !m.isRejected);
    final showDriver = !isDriver;
    final showMerchant = !hasMerchant;
    if (!showDriver && !showMerchant) return const SizedBox.shrink();

    final IconData icon;
    final String title;
    final String subtitle;
    final VoidCallback onTap;
    if (showDriver && showMerchant) {
      icon = Icons.storefront_rounded;
      title = l.earnNudgeBothTitle;
      subtitle = l.earnNudgeBothBody;
      onTap = () => _showChooser(context);
    } else if (showDriver) {
      icon = Icons.directions_car_rounded;
      title = l.becomeDriver;
      subtitle = l.becomeDriverBody;
      onTap = () => context.push(Routes.becomeDriver);
    } else {
      icon = Icons.storefront_rounded;
      title = l.becomeMerchant;
      subtitle = l.becomeMerchantBody;
      onTap = () => context.push(Routes.merchantOnboarding);
    }

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  void _showChooser(BuildContext context) {
    final l = AppL10n.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.directions_car_rounded),
              title: Text(l.becomeDriver),
              subtitle: Text(l.becomeDriverBody),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(Routes.becomeDriver);
              },
            ),
            ListTile(
              leading: const Icon(Icons.storefront_rounded),
              title: Text(l.becomeMerchant),
              subtitle: Text(l.becomeMerchantBody),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push(Routes.merchantOnboarding);
              },
            ),
          ],
        ),
      ),
    );
  }
}
