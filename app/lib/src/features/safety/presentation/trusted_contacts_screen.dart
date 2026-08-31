import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/contact_picker.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/safety_repository.dart';
import '../domain/models.dart';

class TrustedContactsScreen extends ConsumerWidget {
  const TrustedContactsScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final l = AppL10n.of(context);
    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: SafeArea(
          child: StatefulBuilder(
            builder: (sheetContext, setSheetState) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.addTrustedContact,
                  style: Theme.of(sheetContext)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: l.contactNameHint,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.contacts_rounded),
                      onPressed: () async {
                        final picked = await pickContact();
                        if (picked != null) {
                          nameController.text = picked.name;
                          phoneController.text = picked.phone;
                          setSheetState(() {});
                        }
                      },
                    ),
                  ),
                  onChanged: (_) => setSheetState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: l.contactPhoneHint),
                  onChanged: (_) => setSheetState(() {}),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  onPressed: nameController.text.trim().isEmpty ||
                          phoneController.text.trim().isEmpty
                      ? null
                      : () => Navigator.of(sheetContext).pop(true),
                  child: Text(l.addTrustedContact),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || !context.mounted) return;

    try {
      await ref.read(safetyRepositoryProvider).addTrustedContact(
            nameController.text.trim(),
            phoneController.text.trim(),
          );
      Haptics.success();
      ref.invalidate(trustedContactsProvider);
    } on ApiException catch (e) {
      Haptics.error();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  e.isNetwork ? AppL10n.of(context).errorNetwork : e.message)),
        );
      }
    }
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, TrustedContact c) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.removeContact),
        content: Text(l.removeContactConfirm(c.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.removeContact),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(safetyRepositoryProvider).removeTrustedContact(c.id);
      Haptics.success();
      ref.invalidate(trustedContactsProvider);
    } on ApiException catch (e) {
      Haptics.error();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.isNetwork ? l.errorNetwork : e.message)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final async = ref.watch(trustedContactsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.trustedContactsTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1_rounded),
            onPressed: () => _add(context, ref),
          ),
        ],
      ),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(trustedContactsProvider),
        ),
        data: (contacts) {
          if (contacts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child:
                    Text(l.noTrustedContactsYet, textAlign: TextAlign.center),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(trustedContactsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: contacts.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final c = contacts[i];
                return ListTile(
                  leading: CircleAvatar(
                    child:
                        Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : '?'),
                  ),
                  title: Text(c.name),
                  subtitle: Text(c.phone),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _remove(context, ref, c),
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
