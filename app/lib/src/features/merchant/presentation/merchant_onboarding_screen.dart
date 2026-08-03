import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/router/app_router.dart';
import '../data/merchant_repository.dart';

/// Self-service merchant registration: name, type, contact, PAN/VAT + pin.
class MerchantOnboardingScreen extends ConsumerStatefulWidget {
  const MerchantOnboardingScreen({super.key});

  @override
  ConsumerState<MerchantOnboardingScreen> createState() =>
      _MerchantOnboardingScreenState();
}

class _MerchantOnboardingScreenState
    extends ConsumerState<MerchantOnboardingScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _panVat = TextEditingController();
  String _vertical = 'food';
  LatLng? _point;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    ensureLocationPermission().then((_) => currentLatLng()).then((p) {
      if (mounted) setState(() => _point = p);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _panVat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final point = _point;
    if (name.isEmpty || point == null) return;
    setState(() => _busy = true);
    try {
      await ref.read(merchantRepositoryProvider).apply(
            name: name,
            vertical: _vertical,
            point: point,
            address: _address.text.trim(),
            phone: _phone.text.trim(),
            panVat: _panVat.text.trim(),
          );
      ref.invalidate(myMerchantsProvider);
      if (mounted) context.go(Routes.merchantDashboard);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorGeneric)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.becomeMerchant)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l.becomeMerchantBody,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )),
          const SizedBox(height: 20),
          Text(l.storeType, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'food',
                icon: const Icon(Icons.restaurant_rounded),
                label: Text(l.food),
              ),
              ButtonSegment(
                value: 'grocery',
                icon: const Icon(Icons.local_grocery_store_rounded),
                label: Text(l.grocery),
              ),
            ],
            selected: {_vertical},
            onSelectionChanged: (s) => setState(() => _vertical = s.first),
          ),
          const SizedBox(height: 16),
          _Field(controller: _name, label: l.merchantStoreName),
          _Field(
            controller: _phone,
            label: l.phoneNumber,
            keyboardType: TextInputType.phone,
          ),
          _Field(controller: _panVat, label: l.panVat),
          _Field(controller: _address, label: l.addressOptional),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.my_location_rounded),
            title: Text(l.useCurrentLocation),
            subtitle: Text(
              _point == null
                  ? '…'
                  : '${_point!.latitude.toStringAsFixed(5)}, ${_point!.longitude.toStringAsFixed(5)}',
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _busy || _point == null ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.registerStore),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.keyboardType,
  });
  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}
