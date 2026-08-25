import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/router/app_router.dart';
import '../data/marketplace_repository.dart';
import '../domain/models.dart';

/// Search items across every open merchant, sorted by nearest / cheapest / top
/// rated. Tapping a hit opens its merchant so the user can add it to a cart.
class ItemSearchScreen extends ConsumerStatefulWidget {
  const ItemSearchScreen({super.key, this.vertical});

  /// Restrict to 'food' or 'grocery'; null searches both.
  final String? vertical;

  @override
  ConsumerState<ItemSearchScreen> createState() => _ItemSearchScreenState();
}

class _ItemSearchScreenState extends ConsumerState<ItemSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  LatLng? _near;
  String _sort = 'nearest';
  String _query = '';
  List<ItemResult> _results = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    currentLatLng().then((p) {
      if (mounted) setState(() => _near = p);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _query = value;
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 350), _run);
  }

  Future<void> _run() async {
    final q = _query;
    try {
      final hits = await ref.read(marketplaceRepositoryProvider).searchItems(
            q,
            at: _near,
            vertical: widget.vertical,
            sort: _sort,
          );
      if (!mounted || q != _query) return;
      setState(() {
        _results = hits;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setSort(String s) {
    setState(() => _sort = s);
    if (_query.trim().length >= 2) _run();
  }

  void _openMerchant(ItemResult it) {
    // Minimal merchant; the merchant screen loads full details by id.
    final merchant = Merchant(
      id: it.merchantId,
      name: it.merchantName,
      vertical: it.vertical,
      point: const LatLng(0, 0),
      prepMins: 0,
      isOpen: true,
      rating: it.rating,
    );
    context.push(Routes.merchant, extra: merchant);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final sorts = <(String, String)>[
      ('nearest', l.sortNearest),
      ('cheapest', l.sortCheapest),
      ('rating', l.sortTopRated),
    ];
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: l.searchItemsHint,
          ),
        ),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                for (final s in sorts)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(s.$2),
                      selected: _sort == s.$1,
                      onSelected: (_) => _setSort(s.$1),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _query.trim().length < 2
                ? Center(child: Text(l.searchItemsHint))
                : _loading && _results.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _results.isEmpty
                        ? Center(child: Text(l.searchNoResults))
                        : ListView.separated(
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) => _ItemHitTile(
                              item: _results[i],
                              onTap: () => _openMerchant(_results[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _ItemHitTile extends StatelessWidget {
  const _ItemHitTile({required this.item, required this.onTap});
  final ItemResult item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        item.vertical == 'grocery'
            ? Icons.local_grocery_store_rounded
            : Icons.restaurant_menu_rounded,
        color: scheme.onSurfaceVariant,
      ),
    );
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 52,
          height: 52,
          child: item.imageUrl == null
              ? placeholder
              : CachedNetworkImage(
                  imageUrl: item.imageUrl!,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => placeholder,
                  errorWidget: (_, __, ___) => placeholder,
                ),
        ),
      ),
      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        item.distanceKm == null
            ? item.merchantName
            : '${item.merchantName} · ${item.distanceKm!.toStringAsFixed(1)} km',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        'NPR ${item.price.toStringAsFixed(0)}',
        style: TextStyle(fontWeight: FontWeight.w800, color: scheme.primary),
      ),
    );
  }
}
