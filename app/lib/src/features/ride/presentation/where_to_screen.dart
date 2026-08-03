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
  String? _pickupLabel; // null → current location
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

  Future<void> _openSearch({required bool forPickup}) async {
    final pick = await Navigator.of(context).push<AddressPick>(
      MaterialPageRoute(
        builder: (_) => const AddressSearchScreen(allowMap: false),
      ),
    );
    if (pick?.hit == null || !mounted) return;
    final hit = pick!.hit!;
    setState(() {
      if (forPickup) {
        _pickup = hit.point;
        _pickupLabel = hit.label;
      } else {
        _dest = hit.point;
        _destLabel.text = hit.label;
      }
    });
    _mapController.move(hit.point, 15);
  }

  void _continue() {
    if (_pickup == null || _dest == null) return;
    final draft = RideDraft(
      pickup: Place(
        point: _pickup!,
        label: _pickupLabel ?? AppL10n.of(context).useCurrentLocation,
      ),
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
            child: SafeArea(
              top: false,
              child: _Sheet(
                pickupText: _pickupLabel ?? l.useCurrentLocation,
                destText: _dest == null ? null : _destLabel.text,
                vehicle: _vehicle,
                onPickupTap: () => _openSearch(forPickup: true),
                onDestTap: () => _openSearch(forPickup: false),
                onVehicle: (v) => setState(() => _vehicle = v),
                onContinue: _dest == null ? null : _continue,
                onSave: _dest == null ? null : _saveDest,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({
    required this.pickupText,
    required this.destText,
    required this.vehicle,
    required this.onPickupTap,
    required this.onDestTap,
    required this.onVehicle,
    required this.onContinue,
    required this.onSave,
  });

  final String pickupText;
  final String? destText;
  final VehicleClass vehicle;
  final VoidCallback onPickupTap;
  final VoidCallback onDestTap;
  final ValueChanged<VehicleClass> onVehicle;
  final VoidCallback? onContinue;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  _LocationRow(
                    label: l.pickup,
                    dotColor: scheme.primary,
                    icon: Icons.trip_origin,
                    text: pickupText,
                    isPlaceholder: false,
                    onTap: onPickupTap,
                  ),
                  Divider(height: 1, indent: 48, color: scheme.outlineVariant),
                  _LocationRow(
                    label: l.destination,
                    dotColor: scheme.secondary,
                    icon: Icons.location_on_rounded,
                    text: destText ?? l.searchAddressHint,
                    isPlaceholder: destText == null,
                    onTap: onDestTap,
                    trailing: onSave == null
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.bookmark_add_outlined),
                            onPressed: onSave,
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final v in VehicleClass.values)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: v == VehicleClass.values.last ? 0 : 8,
                      ),
                      child: _VehicleCard(
                        selected: vehicle == v,
                        icon: _vehicleIcon(v),
                        label: _vehicleLabel(l, v),
                        onTap: () => onVehicle(v),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: onContinue,
              child: Text(l.fareEstimate),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _vehicleIcon(VehicleClass v) => switch (v) {
      VehicleClass.twoWheeler => Icons.two_wheeler_rounded,
      VehicleClass.threeWheeler => Icons.electric_rickshaw_rounded,
      VehicleClass.fourWheeler => Icons.directions_car_rounded,
    };

String _vehicleLabel(AppL10n l, VehicleClass v) => switch (v) {
      VehicleClass.twoWheeler => l.vehicleTwoWheeler,
      VehicleClass.threeWheeler => l.vehicleThreeWheeler,
      VehicleClass.fourWheeler => l.vehicleFourWheeler,
    };

/// A selectable vehicle-class card (icon + label), inDrive/Yango style.
class _VehicleCard extends StatelessWidget {
  const _VehicleCard({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 28,
                color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 12.5,
                  color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One tappable pickup/destination row inside the ride sheet.
class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.label,
    required this.dotColor,
    required this.icon,
    required this.text,
    required this.isPlaceholder,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final Color dotColor;
  final IconData icon;
  final String text;
  final bool isPlaceholder;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: dotColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                          letterSpacing: 0.6,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isPlaceholder
                        ? TextStyle(color: Theme.of(context).hintColor)
                        : const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
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
