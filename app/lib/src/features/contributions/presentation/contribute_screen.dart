import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/location.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/haptics.dart';
import '../../ride/presentation/widgets/map_view.dart';
import '../data/contributions_repository.dart';
import '../domain/models.dart';

/// Submit a new map contribution. The photo must be captured live (no
/// gallery picker) and a fresh device-GPS fix is taken the instant it's
/// captured — that's the "physically at the location" proof the backend
/// checks against the pinned point before accepting the submission.
class ContributeScreen extends ConsumerStatefulWidget {
  const ContributeScreen({super.key});

  @override
  ConsumerState<ContributeScreen> createState() => _ContributeScreenState();
}

class _ContributeScreenState extends ConsumerState<ContributeScreen> {
  final _mapController = MapController();
  final _name = TextEditingController();
  final _description = TextEditingController();
  ContributionCategory _category = ContributionCategory.organisation;
  LatLng? _point;
  XFile? _photo;
  LatLng? _capturePoint;
  bool _loadingLocation = true;
  bool _capturing = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    final here = await currentLatLng();
    if (!mounted) return;
    setState(() {
      _point = here;
      _loadingLocation = false;
    });
    _mapController.move(here, 17);
  }

  Future<void> _capturePhoto() async {
    setState(() => _capturing = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
      );
      if (file == null) return;
      // The GPS fix that actually matters is the one taken right now, not
      // whatever was loaded when the screen opened — the user may have
      // walked to the spot in between.
      final here = await currentLatLng();
      if (!mounted) return;
      setState(() {
        _photo = file;
        _capturePoint = here;
      });
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  bool get _canSubmit =>
      !_submitting &&
      _point != null &&
      _photo != null &&
      _capturePoint != null &&
      _name.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final l = AppL10n.of(context);
    setState(() => _submitting = true);
    try {
      await ref.read(contributionsRepositoryProvider).submit(
            ContributionSubmission(
              category: _category,
              name: _name.text.trim(),
              description: _description.text.trim().isEmpty
                  ? null
                  : _description.text.trim(),
              point: _point!,
              capturePoint: _capturePoint!,
              photoPath: _photo!.path,
            ),
          );
      Haptics.success();
      ref.invalidate(myContributionsProvider);
      if (mounted) Navigator.of(context).pop(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.contributionSubmitted)),
        );
      }
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.isNetwork ? l.errorNetwork : e.message),
          ),
        );
      }
    } catch (_) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l.errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.contributeToMap)),
      body: _loadingLocation
          ? const Center(child: CircularProgressIndicator())
          // Bottom-only: the AppBar already accounts for the top inset: this
          // is specifically for the submit button clearing the system nav bar.
          : SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(l.contributionLocationLabel,
                      style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 200,
                      child: MapView(
                        controller: _mapController,
                        center: _point ?? const LatLng(28.033, 82.484),
                        zoom: 17,
                        onTap: (p) => setState(() => _point = p),
                        pins: [
                          if (_point != null)
                            MapPin(
                              _point!,
                              Icons.location_on_rounded,
                              Theme.of(context).colorScheme.secondary,
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in ContributionCategory.values)
                        ChoiceChip(
                          label: Text(_categoryLabel(l, c)),
                          selected: _category == c,
                          onSelected: (_) => setState(() => _category = c),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration:
                        InputDecoration(labelText: l.contributionNameHint),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _description,
                    textCapitalization: TextCapitalization.sentences,
                    maxLines: 3,
                    decoration: InputDecoration(
                        labelText: l.contributionDescriptionHint),
                  ),
                  const SizedBox(height: 20),
                  Text(l.contributionPhotoHint,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  if (_photo != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(
                        File(_photo!.path),
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _capturing ? null : _capturePhoto,
                    icon: _capturing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.camera_alt_rounded),
                    label: Text(_photo == null
                        ? l.contributionTakePhoto
                        : l.contributionRetakePhoto),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    child: _submitting
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : Text(l.contributionSubmit),
                  ),
                ],
              ),
            ),
    );
  }

  String _categoryLabel(AppL10n l, ContributionCategory c) => switch (c) {
        ContributionCategory.organisation => l.categoryOrganisation,
        ContributionCategory.building => l.categoryBuilding,
        ContributionCategory.landmark => l.categoryLandmark,
        ContributionCategory.construction => l.categoryConstruction,
        ContributionCategory.closedRoad => l.categoryClosedRoad,
        ContributionCategory.sign => l.categorySign,
        ContributionCategory.other => l.categoryOther,
      };
}
