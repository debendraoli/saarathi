import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/marketplace_repository.dart';
import '../domain/models.dart';
import 'item_search_screen.dart';

enum MarketplaceKind { food, grocery }

enum _Filter { all, offers, rating4, under30 }

/// Merchant discovery for a vertical (food / grocery) — search-first, with
/// promotions and category shortcuts surfaced above the plain list.
class MarketplaceScreen extends ConsumerStatefulWidget {
  const MarketplaceScreen({super.key, required this.kind});
  final MarketplaceKind kind;

  @override
  ConsumerState<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends ConsumerState<MarketplaceScreen> {
  late MarketplaceKind _kind;
  LatLng? _at;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _kind = widget.kind;
    currentLatLng().then((p) {
      if (mounted) setState(() => _at = p);
    });
  }

  String get _vertical => _kind == MarketplaceKind.food ? 'food' : 'grocery';

  List<Merchant> _applyFilter(
    List<Merchant> merchants,
    Map<String, NearbyOffer> offerByMerchant,
  ) {
    switch (_filter) {
      case _Filter.all:
        return merchants;
      case _Filter.offers:
        return merchants
            .where((m) => offerByMerchant.containsKey(m.id))
            .toList();
      case _Filter.rating4:
        return merchants.where((m) => m.rating >= 4.0).toList();
      case _Filter.under30:
        return merchants.where((m) => m.prepMins <= 30).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final merchantsKey = (_vertical, _at);
    final merchants = ref.watch(merchantsProvider(merchantsKey));
    final offers = ref.watch(nearbyOffersProvider(merchantsKey));

    return Scaffold(
      appBar: AppBar(
        title: Text(_kind == MarketplaceKind.food ? l.food : l.grocery),
      ),
      body: merchants.when(
        loading: () => const SkeletonList(padding: EdgeInsets.all(12)),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(merchantsProvider(merchantsKey)),
        ),
        data: (list) {
          final offerList = offers.valueOrNull ?? const <NearbyOffer>[];
          final offerByMerchant = {
            for (final o in offerList) o.merchantId: o,
          };
          final filtered = _applyFilter(list, offerByMerchant);

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(merchantsProvider(merchantsKey));
              ref.invalidate(nearbyOffersProvider(merchantsKey));
            },
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _VerticalToggle(
                        kind: _kind,
                        onChanged: (k) => setState(() {
                          _kind = k;
                          _filter = _Filter.all;
                        }),
                      ),
                      const SizedBox(height: 10),
                      _AnimatedSearchBar(vertical: _vertical),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _CategoryRail(
                  kind: _kind,
                  onTap: (query) => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ItemSearchScreen(
                        vertical: _vertical,
                        initialQuery: query,
                      ),
                    ),
                  ),
                ),
                if (offerList.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _SectionHead(title: l.offersNearYou),
                  ),
                  const SizedBox(height: 10),
                  _OfferCarousel(offers: offerList),
                ],
                const SizedBox(height: 16),
                _FilterChips(
                  value: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SectionHead(title: l.popularNearYou),
                ),
                const SizedBox(height: 8),
                if (list.isEmpty)
                  _EmptyMerchants(kind: _kind)
                else if (filtered.isEmpty)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                    child: Center(
                      child: Text(
                        l.noMerchantsMatchFilter,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final m in filtered) ...[
                          _MerchantCard(
                            merchant: m,
                            offer: offerByMerchant[m.id],
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _VerticalToggle extends StatelessWidget {
  const _VerticalToggle({required this.kind, required this.onChanged});
  final MarketplaceKind kind;
  final ValueChanged<MarketplaceKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ToggleButton(
              label: l.food,
              icon: Icons.ramen_dining_rounded,
              selected: kind == MarketplaceKind.food,
              onTap: () => onChanged(MarketplaceKind.food),
            ),
          ),
          Expanded(
            child: _ToggleButton(
              label: l.grocery,
              icon: Icons.local_grocery_store_rounded,
              selected: kind == MarketplaceKind.grocery,
              onTap: () => onChanged(MarketplaceKind.grocery),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      elevation: selected ? 1 : 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A search bar whose placeholder types and erases through a rotating list
/// of example queries — tapping anywhere opens the real search screen.
class _AnimatedSearchBar extends StatefulWidget {
  const _AnimatedSearchBar({required this.vertical});
  final String vertical;

  @override
  State<_AnimatedSearchBar> createState() => _AnimatedSearchBarState();
}

class _AnimatedSearchBarState extends State<_AnimatedSearchBar> {
  Timer? _timer;
  int _termIndex = 0;
  int _charIndex = 0;
  bool _deleting = false;

  List<String> _terms(AppL10n l) => [
        l.searchHintMomo,
        l.searchHintVegetables,
        l.searchHintChowmein,
        l.searchHintPharmacy,
        l.searchHintShop,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    final terms = _terms(AppL10n.of(context));
    final word = terms[_termIndex % terms.length];
    var delay = const Duration(milliseconds: 55);
    setState(() {
      if (!_deleting) {
        _charIndex++;
        if (_charIndex >= word.length) {
          _deleting = true;
          delay = const Duration(milliseconds: 1400);
        } else {
          delay = const Duration(milliseconds: 55);
        }
      } else {
        _charIndex--;
        if (_charIndex <= 0) {
          _charIndex = 0;
          _deleting = false;
          _termIndex = (_termIndex + 1) % terms.length;
          delay = const Duration(milliseconds: 350);
        } else {
          delay = const Duration(milliseconds: 28);
        }
      }
    });
    _timer = Timer(delay, _tick);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final terms = _terms(l);
    final word = terms[_termIndex % terms.length];
    final shown = word.substring(0, _charIndex.clamp(0, word.length));
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ItemSearchScreen(vertical: widget.vertical),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Icon(Icons.search_rounded, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shown,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 14.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({required this.kind, required this.onTap});
  final MarketplaceKind kind;
  final ValueChanged<String> onTap;

  List<(IconData, String Function(AppL10n))> get _entries {
    if (kind == MarketplaceKind.food) {
      return [
        (Icons.ramen_dining_rounded, (AppL10n l) => l.categoryMomo),
        (Icons.rice_bowl_rounded, (AppL10n l) => l.categoryKhaja),
        (Icons.soup_kitchen_rounded, (AppL10n l) => l.categoryChowmein),
        (Icons.bakery_dining_rounded, (AppL10n l) => l.categoryBakery),
        (Icons.local_drink_rounded, (AppL10n l) => l.categoryDrinks),
      ];
    }
    return [
      (Icons.eco_rounded, (AppL10n l) => l.categoryVegetables),
      (Icons.apple_rounded, (AppL10n l) => l.categoryFruits),
      (Icons.egg_rounded, (AppL10n l) => l.categoryDairy),
      (Icons.grain_rounded, (AppL10n l) => l.categoryGrains),
      (Icons.local_pharmacy_rounded, (AppL10n l) => l.categoryPharmacy),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final entries = _entries;
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (_, i) {
          final (icon, labelFn) = entries[i];
          final label = labelFn(l);
          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onTap(label),
            child: SizedBox(
              width: 60,
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(icon, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

const _kOfferGradients = [
  [Color(0xFFE0791B), Color(0xFFF5A623)],
  [Color(0xFFB30F34), Color(0xFFDC143C)],
  [Color(0xFF136B3F), Color(0xFF1C8A4B)],
  [Color(0xFF22506B), Color(0xFF3F8BAE)],
];

List<Color> _gradientFor(String id) =>
    _kOfferGradients[id.hashCode.abs() % _kOfferGradients.length];

/// Auto-advancing carousel of real, active store offers — pauses on touch.
class _OfferCarousel extends StatefulWidget {
  const _OfferCarousel({required this.offers});
  final List<NearbyOffer> offers;

  @override
  State<_OfferCarousel> createState() => _OfferCarouselState();
}

class _OfferCarouselState extends State<_OfferCarousel> {
  final _controller = PageController(viewportFraction: 0.86);
  Timer? _auto;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    if (widget.offers.length > 1) {
      _auto = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted || !_controller.hasClients) return;
        final next = (_page + 1) % widget.offers.length;
        _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    _auto?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 108,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.offers.length,
        onPageChanged: (i) => _page = i,
        itemBuilder: (_, i) {
          final o = widget.offers[i];
          final grad = _gradientFor(o.id);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => context.push(
                Routes.merchant,
                extra: Merchant(
                  id: o.merchantId,
                  name: o.merchantName,
                  vertical: o.vertical,
                  point: const LatLng(0, 0),
                  prepMins: 0,
                  isOpen: true,
                  rating: 0,
                ),
              ),
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(
                    colors: grad,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      o.merchantName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      o.badgeText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (o.qualifier.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        o.qualifier,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.value, required this.onChanged});
  final _Filter value;
  final ValueChanged<_Filter> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final options = <(_Filter, String, IconData)>[
      (_Filter.all, l.filterAll, Icons.apps_rounded),
      (_Filter.offers, l.filterOffers, Icons.local_offer_rounded),
      (_Filter.rating4, l.filterRating4, Icons.star_rounded),
      (_Filter.under30, l.filterUnder30Min, Icons.schedule_rounded),
    ];
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final (f, label, icon) = options[i];
          final selected = value == f;
          return ChoiceChip(
            selected: selected,
            onSelected: (_) => onChanged(f),
            avatar: Icon(icon, size: 15),
            label: Text(label),
            labelStyle:
                const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
          );
        },
      ),
    );
  }
}

class _MerchantCard extends StatelessWidget {
  const _MerchantCard({required this.merchant, this.offer});
  final Merchant merchant;
  final NearbyOffer? offer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final grad = _gradientFor(merchant.id);
    final fallbackIcon = merchant.vertical == 'grocery'
        ? Icons.local_grocery_store_rounded
        : Icons.restaurant_rounded;

    // A real border + soft shadow instead of the app's default flat
    // CardTheme (elevation 0, a surface tint one shade off the page
    // background, no border) — scoped to this card rather than the global
    // theme, since a dozen of these in a row is exactly where "no edges"
    // reads worst: they blur into one continuous strip instead of a list of
    // distinct shops.
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.09),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.merchant, extra: merchant),
        child: Padding(
          padding: const EdgeInsets.all(9),
          // Fixed to the photo's own height so the Row's cross axis is
          // bounded — without this, the meta row's Spacer() (below) sits in
          // a Column stretched by an unbounded-height Row (this card is a
          // ListView item, and Row's cross axis inherits that unbounded
          // height unless something here pins it), which is the classic
          // "flex child with unbounded constraints" crash: RenderFlex
          // throws during layout, and since this Row lives inside the
          // ListView's shared Viewport, that one exception blanks the
          // entire scroll view, not just this card.
          child: SizedBox(
            height: 88,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        gradient: LinearGradient(
                          colors: grad,
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      alignment: Alignment.center,
                      child:
                          Icon(fallbackIcon, color: Colors.white70, size: 30),
                    ),
                    if (merchant.isOpen)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Colors.green.shade700,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                        ),
                      ),
                    if (offer != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          decoration: const BoxDecoration(
                            color: Color(0xCC000000),
                            borderRadius: BorderRadius.only(
                              bottomLeft: Radius.circular(13),
                              bottomRight: Radius.circular(13),
                            ),
                          ),
                          child: Text(
                            offer!.badgeText,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              merchant.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.tertiaryContainer,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.star_rounded,
                                    size: 12,
                                    color: scheme.onTertiaryContainer),
                                const SizedBox(width: 2),
                                Text(
                                  merchant.rating.toStringAsFixed(1),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: scheme.onTertiaryContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (merchant.address != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          merchant.address!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.schedule_rounded,
                              size: 13, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 3),
                          Text('${merchant.prepMins}m',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onSurfaceVariant)),
                          if (merchant.distanceKm != null) ...[
                            const SizedBox(width: 10),
                            Icon(Icons.near_me_rounded,
                                size: 12, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 3),
                            Text(
                              '${merchant.distanceKm!.toStringAsFixed(1)} km',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onSurfaceVariant),
                            ),
                          ],
                          const Spacer(),
                          if (!merchant.isOpen)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Closed',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyMerchants extends StatelessWidget {
  const _EmptyMerchants({required this.kind});
  final MarketplaceKind kind;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            kind == MarketplaceKind.food
                ? Icons.restaurant_rounded
                : Icons.local_grocery_store_rounded,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            l.comingSoonTitle,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(l.comingSoonBody, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
