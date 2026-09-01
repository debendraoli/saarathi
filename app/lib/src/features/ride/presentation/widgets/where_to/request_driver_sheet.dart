import 'package:flutter/material.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../../../shared/contact_picker.dart';

/// Request a specific driver by phone number — sends them the trip first,
/// ahead of normal matching. UI shell only for now: wiring this to a real
/// backend "priority offer" endpoint is a separate, explicitly-scoped
/// backend change (driver lookup + a priority-offer dispatch path), not yet
/// built — this dialog is where that submission will hook in.
void showRequestDriverSheet(
  BuildContext context,
  ValueChanged<String> onSubmit,
) {
  final l = AppL10n.of(context);
  final controller = TextEditingController();
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
      ),
      child: SafeArea(
        child: StatefulBuilder(
          builder: (sheetContext, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Theme.of(sheetContext).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                l.requestSpecificDriver,
                style: Theme.of(sheetContext)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                l.requestSpecificDriverBody,
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l.driverPhoneLabel,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.contacts_rounded),
                    tooltip: l.pickFromContacts,
                    onPressed: () async {
                      final phone = await pickContactPhone();
                      if (phone != null) {
                        controller.text = phone;
                        setSheetState(() {});
                      }
                    },
                  ),
                ),
                onChanged: (_) => setSheetState(() {}),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: controller.text.trim().isEmpty
                    ? null
                    : () {
                        onSubmit(controller.text.trim());
                        Navigator.of(sheetContext).pop();
                      },
                child: Text(l.requestSpecificDriver),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.notifications_active_rounded,
                    size: 16,
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l.driverWillBeNotified,
                      style:
                          Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                                color: Theme.of(sheetContext)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
