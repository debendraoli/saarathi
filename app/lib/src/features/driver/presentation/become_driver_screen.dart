import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../auth/application/auth_controller.dart';
import '../../ride/domain/models.dart';
import '../data/driver_kyc_repository.dart';

/// Driver registration: vehicle + personal details. On success the account is
/// promoted rider→driver and we move to document upload.
class BecomeDriverScreen extends ConsumerStatefulWidget {
  const BecomeDriverScreen({super.key});

  @override
  ConsumerState<BecomeDriverScreen> createState() => _BecomeDriverScreenState();
}

class _BecomeDriverScreenState extends ConsumerState<BecomeDriverScreen> {
  final _plate = TextEditingController();
  final _license = TextEditingController();
  final _address = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  VehicleClass _class = VehicleClass.twoWheeler;
  DateTime? _dob;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _plate.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_plate, _license, _address, _make, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 25),
      firstDate: DateTime(now.year - 80),
      lastDate: DateTime(now.year - 18),
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _submit() async {
    if (_plate.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final two = (int n) => n.toString().padLeft(2, '0');
      await ref.read(driverKycRepositoryProvider).register(DriverInput(
            vehicleClass: _class,
            plateNumber: _plate.text.trim(),
            licenseNumber: _license.text.trim().isEmpty ? null : _license.text.trim(),
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
            make: _make.text.trim().isEmpty ? null : _make.text.trim(),
            model: _model.text.trim().isEmpty ? null : _model.text.trim(),
            dateOfBirth: _dob == null
                ? null
                : '${_dob!.year}-${two(_dob!.month)}-${two(_dob!.day)}',
          ));
      await ref.read(authControllerProvider.notifier).refresh();
      if (mounted) context.pushReplacement(Routes.kyc);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(AppL10n.of(context).errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.becomeDriverTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Vehicle', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
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
            selected: {_class},
            onSelectionChanged: (s) => setState(() => _class = s.first),
          ),
          const SizedBox(height: 16),
          _Field(controller: _plate, label: 'Plate number', hint: 'BA-1-PA-1234'),
          _Field(controller: _make, label: 'Make (optional)'),
          _Field(controller: _model, label: 'Model (optional)'),
          const Divider(height: 32),
          _Field(controller: _license, label: 'License number'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Date of birth'),
            subtitle: Text(_dob == null
                ? 'Not set'
                : '${_dob!.year}-${_dob!.month}-${_dob!.day}'),
            trailing: const Icon(Icons.calendar_today_rounded),
            onTap: _pickDob,
          ),
          _Field(controller: _address, label: 'Address'),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || _plate.text.trim().isEmpty ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                : Text(l.registerAction),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.controller, required this.label, this.hint});
  final TextEditingController controller;
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}
