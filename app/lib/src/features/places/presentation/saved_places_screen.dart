import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/places_repository.dart';
import 'address_search_screen.dart';

/// Manage saved places (home, work, and other frequent spots): view, add via
/// the address search flow, and remove.
class SavedPlacesScreen extends ConsumerWidget {
  const SavedPlacesScreen({super.key});

  IconData _iconFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('home')) return Icons.home_rounded;
    if (l.contains('work') || l.contains('office')) return Icons.work_rounded;
    return Icons.bookmark_rounded;
  }

  Future<void> _addPlace(BuildContext context, WidgetRef ref) async {
    final l = AppL10n.of(context);
    final pick = await Navigator.of(context).push<AddressPick>(
      MaterialPageRoute(
        builder: (_) => AddressSearchScreen(title: l.addPlace, allowMap: false),
      ),
    );
    final hit = pick?.hit;
    if (hit == null || !context.mounted) return;

    final labelController = TextEditingController(text: hit.label);
    final label = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.addPlace),
        content: TextField(
          controller: labelController,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: l.placeLabelHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, labelController.text.trim()),
            child: Text(l.saveAction),
          ),
        ],
      ),
    );
    if (label == null || label.isEmpty) return;

    try {
      await ref
          .read(placesRepositoryProvider)
          .add(label, hit.point, address: hit.address);
      Haptics.success();
      ref.invalidate(savedPlacesProvider);
    } catch (_) {
      Haptics.error();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    }
  }

  Future<void> _removePlace(
    BuildContext context,
    WidgetRef ref,
    SavedPlace place,
  ) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.removePlace),
        content: Text(l.removePlaceConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.removePlace),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    Haptics.warning();

    try {
      await ref.read(placesRepositoryProvider).remove(place.id);
      ref.invalidate(savedPlacesProvider);
    } catch (_) {
      Haptics.error();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).errorNetwork)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(savedPlacesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.savedPlaces)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addPlace(context, ref),
        icon: const Icon(Icons.add),
        label: Text(l.addPlace),
      ),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(savedPlacesProvider),
        ),
        data: (places) {
          if (places.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l.savedPlacesEmpty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(savedPlacesProvider),
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: places.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final p = places[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(_iconFor(p.label)),
                  ),
                  title: Text(p.label),
                  subtitle: p.address == null || p.address!.isEmpty
                      ? null
                      : Text(p.address!,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    tooltip: l.removePlace,
                    onPressed: () => _removePlace(context, ref, p),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
