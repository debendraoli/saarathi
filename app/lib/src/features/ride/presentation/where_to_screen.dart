import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/location.dart';
import '../../../core/router/app_router.dart';
import '../domain/models.dart';
import 'widgets/map_view.dart';

/// Pick pickup (defaults to current location) + destination (tap the map or type
/// a landmark), choose bike/car, then estimate. Landmark-friendly for Dang.
class WhereToScreen extends ConsumerStatefulWidget {
  const WhereToScreen({super.key});

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
    _loadLocation();
  }

  @override
  void dispose() {
    _destLabel.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    final here = await currentLatLng();
    if (!mounted) return;
    setState(() => _pickup = here);
    _mapController.move(here, 15);
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
                MapPin(_pickup!, Icons.my_location_rounded,
                    Theme.of(context).colorScheme.primary),
              if (_dest != null)
                MapPin(_dest!, Icons.location_on_rounded,
                    Theme.of(context).colorScheme.secondary),
            ],
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _Sheet(
              destLabel: _destLabel,
              hasDest: _dest != null,
              vehicle: _vehicle,
              onVehicle: (v) => setState(() => _vehicle = v),
              onContinue: _dest == null ? null : _continue,
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
    required this.onVehicle,
    required this.onContinue,
  });

  final TextEditingController destLabel;
  final bool hasDest;
  final VehicleClass vehicle;
  final ValueChanged<VehicleClass> onVehicle;
  final VoidCallback? onContinue;

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
            Row(
              children: [
                Icon(Icons.location_on_rounded,
                    size: 18, color: Theme.of(context).colorScheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: destLabel,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: hasDest ? l.landmarkHint : l.chooseOnMap,
                    ),
                  ),
                ),
              ],
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
