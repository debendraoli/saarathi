import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/haptics.dart';
import '../../ride/domain/models.dart';
import '../../ride/presentation/widgets/map_view.dart';
import '../data/delivery_repository.dart';
import '../domain/models.dart';

/// Send a parcel: pick pickup (current location) + drop (tap the map), recipient
/// details and size, then book. Creates a trackable `delivery` trip.
class ParcelScreen extends ConsumerStatefulWidget {
  const ParcelScreen({super.key});

  @override
  ConsumerState<ParcelScreen> createState() => _ParcelScreenState();
}

class _ParcelScreenState extends ConsumerState<ParcelScreen> {
  final _mapController = MapController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _cod = TextEditingController();
  final _note = TextEditingController();

  LatLng? _pickup;
  LatLng? _drop;
  ParcelSize _size = ParcelSize.small;
  bool _fragile = false;
  DeliveryEstimate? _estimate;
  bool _booking = false;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _cod, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadLocation() async {
    final here = await currentLatLng();
    if (!mounted) return;
    setState(() => _pickup = here);
    _mapController.move(here, 15);
  }

  Future<void> _refreshEstimate() async {
    if (_pickup == null || _drop == null) return;
    try {
      final est = await ref.read(deliveryRepositoryProvider).estimate(
            origin: _pickup!,
            dest: _drop!,
            size: _size,
            fragile: _fragile,
          );
      if (mounted) setState(() => _estimate = est);
    } catch (_) {/* leave prior estimate */}
  }

  bool get _canBook =>
      _pickup != null &&
      _drop != null &&
      _name.text.trim().isNotEmpty &&
      _phone.text.trim().isNotEmpty;

  Future<void> _book() async {
    if (!_canBook) return;
    setState(() => _booking = true);
    try {
      final trip = await ref.read(deliveryRepositoryProvider).book(
            ParcelDraft(
              origin: Place(point: _pickup!),
              dest: Place(point: _drop!),
              size: _size,
              recipientName: _name.text.trim(),
              recipientPhone: _phone.text.trim(),
              fragile: _fragile,
              codAmount: double.tryParse(_cod.text.trim()) ?? 0,
              pickupNote: _note.text.trim(),
            ),
          );
      Haptics.success();
      if (mounted) context.go('${Routes.trip}/${trip.id}');
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.parcelTitle)),
      body: Column(
        children: [
          SizedBox(
            height: 220,
            child: MapView(
              controller: _mapController,
              center: _pickup ?? const LatLng(28.033, 82.484),
              onTap: (p) {
                setState(() => _drop = p);
                _refreshEstimate();
              },
              pins: [
                if (_pickup != null)
                  MapPin(_pickup!, Icons.trip_origin,
                      Theme.of(context).colorScheme.primary),
                if (_drop != null)
                  MapPin(_drop!, Icons.location_on_rounded,
                      Theme.of(context).colorScheme.secondary),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_drop == null)
                  Text(
                    l.chooseOnMap,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                SegmentedButton<ParcelSize>(
                  segments: [
                    for (final s in ParcelSize.values)
                      ButtonSegment(value: s, label: Text(s.label)),
                  ],
                  selected: {_size},
                  onSelectionChanged: (s) {
                    setState(() => _size = s.first);
                    _refreshEstimate();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.fragile),
                  value: _fragile,
                  onChanged: (v) {
                    setState(() => _fragile = v);
                    _refreshEstimate();
                  },
                ),
                TextField(
                  controller: _name,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: l.recipientName),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: l.recipientPhone),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _cod,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Cash to collect (COD)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _note,
                  decoration: const InputDecoration(
                      labelText: 'Pickup note (optional)'),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_estimate != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(l.deliveryFee),
                      Text(
                        'NPR ${_estimate!.deliveryFee.toStringAsFixed(0)}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              FilledButton(
                onPressed: _canBook && !_booking ? _book : null,
                child: _booking
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Text(l.bookDelivery),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
