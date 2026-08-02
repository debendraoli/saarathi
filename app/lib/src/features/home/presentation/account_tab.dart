import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/prefs.dart';
import '../../auth/application/auth_controller.dart';

class AccountTab extends ConsumerWidget {
  const AccountTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final user = ref.watch(authControllerProvider).user;
    final locale = ref.watch(localeControllerProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: CircleAvatar(
              radius: 26,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Text(
                (user?.fullName?.isNotEmpty ?? false)
                    ? user!.fullName![0].toUpperCase()
                    : '👤',
                style: const TextStyle(fontSize: 20),
              ),
            ),
            title: Text(
              user?.fullName?.isNotEmpty == true ? user!.fullName! : (user?.phone ?? ''),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(user?.phone ?? ''),
            trailing: IconButton(
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => _editName(context, ref, user?.fullName ?? ''),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(l.chooseLanguage, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'en', label: Text(l.languageEnglish)),
            ButtonSegment(value: 'ne', label: Text(l.languageNepali)),
          ],
          selected: {locale?.languageCode ?? 'en'},
          onSelectionChanged: (s) =>
              ref.read(localeControllerProvider.notifier).set(Locale(s.first)),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(AppL10n.of(context).editName),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: AppL10n.of(context).yourName),
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
    if (name != null && name.isNotEmpty) {
      await ref.read(authControllerProvider.notifier).updateName(name);
    }
  }
}
