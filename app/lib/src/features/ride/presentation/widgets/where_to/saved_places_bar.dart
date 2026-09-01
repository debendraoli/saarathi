import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../places/data/places_repository.dart';

/// Quick-pick chips for the user's saved places (Home / Work / favourites).
class SavedPlacesBar extends ConsumerWidget {
  const SavedPlacesBar({super.key, required this.onPick});
  final void Function(SavedPlace) onPick;

  IconData _iconFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('home')) return Icons.home_rounded;
    if (l.contains('work') || l.contains('office')) return Icons.work_rounded;
    return Icons.bookmark_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(savedPlacesProvider).value ?? const [];
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
