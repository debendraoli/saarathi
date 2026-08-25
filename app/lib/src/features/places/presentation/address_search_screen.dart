import 'dart:async';

import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../data/maps_url_parser.dart';
import '../data/places_repository.dart';

/// Result of the address picker: a chosen place, or a request to pick on the map.
class AddressPick {
  const AddressPick.place(this.hit)
      : chooseOnMap = false,
        forceDestination = false,
        originHit = null;
  const AddressPick.map()
      : hit = null,
        chooseOnMap = true,
        forceDestination = false,
        originHit = null;
  /// A resolved Google Maps link — [hit] (the destination) should be used
  /// regardless of which field (pickup, destination, or a stop) was open
  /// when it was pasted/shared. [originHit] is only set for a "Directions"
  /// link that also encoded a start point; when present, the caller should
  /// set it as pickup too, overriding whatever field was actually open.
  const AddressPick.mapsLink(this.hit, {this.originHit})
      : chooseOnMap = false,
        forceDestination = true;
  final PlaceHit? hit;
  final PlaceHit? originHit;
  final bool chooseOnMap;
  final bool forceDestination;
}

/// Yango-style destination search: type to autocomplete addresses (biased to the
/// user's location), or pick from saved places, recent searches, current
/// location, or the map. Pops an [AddressPick].
class AddressSearchScreen extends ConsumerStatefulWidget {
  const AddressSearchScreen({super.key, this.title, this.allowMap = true});
  final String? title;
  final bool allowMap;

  @override
  ConsumerState<AddressSearchScreen> createState() =>
      _AddressSearchScreenState();
}

class _AddressSearchScreenState extends ConsumerState<AddressSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  LatLng? _near;
  List<PlaceHit> _results = const [];
  bool _loading = false;
  String _query = '';

  /// Aborts the in-flight `/v1/geo/search` call itself (not just its
  /// result) when a newer keystroke supersedes it — the `q != _query`
  /// staleness check below already keeps a superseded response from
  /// overwriting fresher results, this just stops wasting the request too.
  CancelToken? _searchCancel;

  @override
  void initState() {
    super.initState();
    _prepareLocation();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCancel?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _prepareLocation() async {
    // Trigger the permission prompt on entry so results can be distance-sorted.
    await ensureLocationPermission();
    final here = await currentLatLng();
    if (mounted) setState(() => _near = here);
  }

  void _onChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _searchCancel?.cancel();
    if (value.trim().length < 2) {
      setState(() {
        _results = const [];
        _loading = false;
      });
      return;
    }
    if (looksLikeGoogleMapsUrl(value)) {
      setState(() => _loading = true);
      _resolveMapsUrl(value);
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  /// A pasted Google Maps share link resolves straight to a pin — skips the
  /// `/v1/geo/search` autocomplete entirely, since it has no idea what to do
  /// with a raw coordinate pair. A "Directions" link with both ends
  /// resolves both — see [AddressPick.mapsLink]'s `originHit`.
  Future<void> _resolveMapsUrl(String value) async {
    final resolved = await resolveGoogleMapsUrl(value);
    if (!mounted || value != _query) return;
    if (resolved == null) {
      setState(() => _loading = false);
      return;
    }
    final repo = ref.read(placesRepositoryProvider);
    final destReversed =
        await repo.reverse(resolved.destination).catchError((_) => null);
    PlaceHit? originHit;
    if (resolved.origin != null) {
      final originReversed =
          await repo.reverse(resolved.origin!).catchError((_) => null);
      originHit = originReversed ??
          PlaceHit(label: coordLabel(resolved.origin!), point: resolved.origin!);
    }
    if (!mounted || value != _query) return;
    setState(() => _loading = false);
    final destHit = destReversed ??
        PlaceHit(label: coordLabel(resolved.destination), point: resolved.destination);
    // Not `_select` — a Maps link is destination-first with no "which end
    // is this" context, so it always lands on the destination, regardless
    // of whether this screen was opened for pickup, destination, or a stop.
    repo.addRecent(destHit).ignore();
    if (originHit != null) repo.addRecent(originHit).ignore();
    Navigator.of(context).pop(AddressPick.mapsLink(destHit, originHit: originHit));
  }

  Future<void> _runSearch() async {
    final q = _query;
    final cancelToken = CancelToken();
    _searchCancel = cancelToken;
    try {
      final hits = await ref
          .read(placesRepositoryProvider)
          .search(q, near: _near, cancelToken: cancelToken);
      if (!mounted || q != _query) return;
      setState(() {
        _results = hits;
        _loading = false;
      });
    } catch (e) {
      // Cancelled means a newer search already took over _loading/_results
      // — nothing to reset here.
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      if (mounted) setState(() => _loading = false);
    }
  }

  void _select(PlaceHit hit) {
    // Remember it, best-effort, then hand it back.
    ref.read(placesRepositoryProvider).addRecent(hit).ignore();
    Navigator.of(context).pop(AddressPick.place(hit));
  }

  Future<void> _useCurrentLocation() async {
    final l = AppL10n.of(context);
    final here = _near ?? await currentLatLng();
    final reversed =
        await ref.read(placesRepositoryProvider).reverse(here).catchError((_) {
      return null;
    });
    final hit = reversed ??
        PlaceHit(label: l.useCurrentLocation, address: '', point: here);
    if (mounted) _select(hit);
  }

  double? _distanceKm(LatLng point) {
    if (_near == null) return null;
    return const Distance().as(LengthUnit.Kilometer, _near!, point);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final searching = _query.trim().length >= 2;

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
            hintText: widget.title ?? l.searchAddressHint,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
        ),
      ),
      body: searching
          ? _ResultsList(
              loading: _loading,
              results: _results,
              distanceKm: _distanceKm,
              onTap: _select,
              emptyLabel: l.searchNoResults,
            )
          : _Suggestions(
              near: _near,
              allowMap: widget.allowMap,
              onCurrent: _useCurrentLocation,
              onMap: () => Navigator.of(context).pop(const AddressPick.map()),
              onPick: _select,
              distanceKm: _distanceKm,
            ),
    );
  }
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({
    required this.loading,
    required this.results,
    required this.distanceKm,
    required this.onTap,
    required this.emptyLabel,
  });

  final bool loading;
  final List<PlaceHit> results;
  final double? Function(LatLng) distanceKm;
  final void Function(PlaceHit) onTap;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (loading && results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (results.isEmpty) {
      return Center(child: Text(emptyLabel));
    }
    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _PlaceTile(
        hit: results[i],
        distanceKm: distanceKm(results[i].point),
        icon: Icons.location_on_outlined,
        onTap: () => onTap(results[i]),
      ),
    );
  }
}

class _Suggestions extends ConsumerWidget {
  const _Suggestions({
    required this.near,
    required this.allowMap,
    required this.onCurrent,
    required this.onMap,
    required this.onPick,
    required this.distanceKm,
  });

  final LatLng? near;
  final bool allowMap;
  final VoidCallback onCurrent;
  final VoidCallback onMap;
  final void Function(PlaceHit) onPick;
  final double? Function(LatLng) distanceKm;

  IconData _iconFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('home')) return Icons.home_rounded;
    if (l.contains('work') || l.contains('office')) return Icons.work_rounded;
    return Icons.bookmark_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final saved = ref.watch(savedPlacesProvider).valueOrNull ?? const [];
    final recent = ref.watch(recentSearchesProvider).valueOrNull ?? const [];

    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.my_location_rounded),
          title: Text(l.useCurrentLocation),
          subtitle: Text(l.pickupGpsHint),
          onTap: onCurrent,
        ),
        if (allowMap)
          ListTile(
            leading: const Icon(Icons.map_rounded),
            title: Text(l.chooseOnMap),
            onTap: onMap,
          ),
        if (saved.isNotEmpty) ...[
          const Divider(height: 1),
          _SectionHeader(l.savedPlaces),
          for (final p in saved)
            _PlaceTile(
              hit: PlaceHit(
                label: p.label,
                address: p.address ?? '',
                point: p.point,
              ),
              distanceKm: distanceKm(p.point),
              icon: _iconFor(p.label),
              onTap: () => onPick(
                PlaceHit(
                  label: p.label,
                  address: p.address ?? '',
                  point: p.point,
                ),
              ),
            ),
        ],
        if (recent.isNotEmpty) ...[
          const Divider(height: 1),
          _SectionHeader(l.recentSearches),
          for (final h in recent)
            _PlaceTile(
              hit: h,
              distanceKm: distanceKm(h.point),
              icon: Icons.history_rounded,
              onTap: () => onPick(h),
            ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.hit,
    required this.icon,
    required this.onTap,
    this.distanceKm,
  });

  final PlaceHit hit;
  final IconData icon;
  final VoidCallback onTap;
  final double? distanceKm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: scheme.surfaceContainerHighest,
        child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
      ),
      title: Text(hit.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: hit.address.isEmpty
          ? null
          : Text(hit.address, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: distanceKm == null
          ? null
          : Text(
              distanceKm! < 1
                  ? '${(distanceKm! * 1000).round()} m'
                  : '${distanceKm!.toStringAsFixed(1)} km',
              style: Theme.of(context).textTheme.bodySmall,
            ),
      onTap: onTap,
    );
  }
}
