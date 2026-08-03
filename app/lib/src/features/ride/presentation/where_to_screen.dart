import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/router/app_router.dart';
import '../../places/data/places_repository.dart';
import '../../places/presentation/address_search_screen.dart';
import '../domain/models.dart';
import 'widgets/map_view.dart';

/// Pick pickup (defaults to current location) + destination (search, tap the map,
/// or a saved place), choose bike/car, then estimate. Landmark-friendly for Dang.
class WhereToScreen extends ConsumerStatefulWidget {
  const WhereToScreen({super.key, this.initialDest});

  /// Destination chosen upstream (from the home address search), if any.
  final PlaceHit? initialDest;

  @override
  ConsumerState<WhereToScreen> createState() => _WhereToScreenState();
}

class _WhereToScreenState extends ConsumerState<WhereToScreen> {
  final _mapController = MapController();
  final _destLabel = TextEditingController();
  LatLng? _pickup;
  LatLng? _dest;
  VehicleClass _vehicle = VehicleClass.twoWheeler;

  @override
  void initState() {
    super.initState();
    final d = widget.initialDest;
    if (d != null) {
      _dest = d.point;
      _destLabel.text = d.label;
    }
    _loadLocation();
  }

  @override
  void dispose() {
    _destLabel.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    await ensureLocationPermission();
    final here = await currentLatLng();
    if (!mounted) return;
    setState(() => _pickup = here);
    // Keep an upstream-chosen destination centred; otherwise centre on pickup.
    _mapController.move(_dest ?? here, 15);
  }

  Future<void> _openSearch() async {
    final pick = await Navigator.of(context).push<AddressPick>(
      MaterialPageRoute(
        builder: (_) => const AddressSearchScreen(allowMap: false),
      ),
    );
    if (pick?.hit == null || !mounted) return;
    setState(() {
      _dest = pick!.hit!.point;
      _destLabel.text = pick.hit!.label;
    });
    _mapController.move(pick!.hit!.point, 15);
  }

  void _continue() {
    if (_pickup == null || _dest == null) return;
    final draft = RideDraft(
      pickup: Place(point: _pickup!, label: 'Current location'),
      destination: Place(point: _dest!, label: _destLabel.text.trim()),
      vehicleClass: _vehicle,
    );
    context.push(Routes.confirm, extra: draft);
  }

  void _pickSaved(SavedPlace place) {
    setState(() {
      _dest = place.point;
      _destLabel.text = place.label;
    });
    _mapController.move(place.point, 15);
  }

  Future<void> _saveDest() async {
    if (_dest == null) return;
    final controller = TextEditingController(text: _destLabel.text.trim());
    final label = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Save place'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Home, Work, …'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppL10n.of(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppL10n.of(context).saveAction),
          ),
        ],
      ),
    );
    if (label == null || label.isEmpty) return;
    try {
      await ref
          .read(placesRepositoryProvider)
          .add(label, _dest!, address: _destLabel.text.trim());
      ref.invalidate(savedPlacesProvider);
    } catch (_) {/* non-blocking */}
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final center = _pickup ?? const LatLng(28.033, 82.484);
    return Scaffold(
      appBar: AppBar(title: Text(l.whereTo)),
      body: Stack(
        children: [
          MapView(
            controller: _mapController,
            center: center,
            onTap: (p) => setState(() => _dest = p),
            pins: [
              if (_pickup != null)
                MapPin(
                  _pickup!,
                  Icons.my_location_rounded,
                  Theme.of(context).colorScheme.primary,
                ),
              if (_dest != null)
                MapPin(
                  _dest!,
                  Icons.location_on_rounded,
                  Theme.of(context).colorScheme.secondary,
                ),
            ],
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: _SavedPlacesBar(onPick: _pickSaved),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _Sheet(
              destLabel: _destLabel,
              hasDest: _dest != null,
              vehicle: _vehicle,
              onSearch: _openSearch,
              onVehicle: (v) => setState(() => _vehicle = v),
              onContinue: _dest == null ? null : _continue,
              onSave: _dest == null ? null : _saveDest,
            ),
          ),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.destLabel,
    required this.hasDest,
    required this.vehicle,
    required this.onSearch,
    required this.onVehicle,
    required this.onContinue,
    required this.onSave,
  });

  final TextEditingController destLabel;
  final bool hasDest;
  final VehicleClass vehicle;
  final VoidCallback onSearch;
  final ValueChanged<VehicleClass> onVehicle;
  final VoidCallback? onContinue;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.trip_origin, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(l.useCurrentLocation)),
              ],
            ),
            const Divider(height: 20),
            InkWell(
              onTap: onSearch,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.location_on_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        hasDest ? destLabel.text : l.searchAddressHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: hasDest
                            ? null
                            : TextStyle(
                                color: Theme.of(context).hintColor,
                              ),
                      ),
                    ),
                    if (onSave != null)
                      IconButton(
                        icon: const Icon(Icons.bookmark_add_outlined),
                        onPressed: onSave,
                      )
                    else
                      Icon(
                        Icons.search_rounded,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<VehicleClass>(
              segments: [
                ButtonSegment(
                  value: VehicleClass.twoWheeler,
                  icon: const Icon(Icons.two_wheeler_rounded),
                  label: Text(l.vehicleTwoWheeler),
                ),
                ButtonSegment(
                  value: VehicleClass.fourWheeler,
                  icon: const Icon(Icons.directions_car_rounded),
                  label: Text(l.vehicleFourWheeler),
                ),
              ],
              selected: {vehicle},
              onSelectionChanged: (s) => onVehicle(s.first),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onContinue,
              child: Text(l.fareEstimate),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quick-pick chips for the user's saved places (Home / Work / favourites).
class _SavedPlacesBar extends ConsumerWidget {
  const _SavedPlacesBar({required this.onPick});
  final void Function(SavedPlace) onPick;

  IconData _iconFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('home')) return Icons.home_rounded;
    if (l.contains('work') || l.contains('office')) return Icons.work_rounded;
    return Icons.bookmark_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(savedPlacesProvider).valueOrNull ?? const [];
    if (places.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final p in places)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: Icon(_iconFor(p.label), size: 18),
                label: Text(p.label),
                onPressed: () => onPick(p),
              ),
            ),
        ],
      ),
    );
  }
}
