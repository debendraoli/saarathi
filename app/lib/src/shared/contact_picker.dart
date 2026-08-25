import 'package:flutter_contacts/flutter_contacts.dart';

class PickedContact {
  const PickedContact({required this.name, required this.phone});
  final String name;
  final String phone;
}

/// Opens the system contact picker and returns the picked contact's display
/// name + first phone number (digits and leading `+` only). Null if
/// permission is denied, the user backs out, or the picked contact has no
/// phone number.
Future<PickedContact?> pickContact() async {
  if (!await FlutterContacts.permissions.has(PermissionType.read)) {
    final status = await FlutterContacts.permissions.request(
      PermissionType.read,
    );
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.limited) {
      return null;
    }
  }
  final contact = await FlutterContacts.native.showPicker(
    properties: {ContactProperty.phone},
  );
  if (contact == null || contact.phones.isEmpty) return null;
  final phone = contact.phones.first.number.replaceAll(RegExp(r'[^\d+]'), '');
  return PickedContact(name: contact.displayName ?? '', phone: phone);
}

/// Phone-only convenience for callers that don't need the contact's name.
Future<String?> pickContactPhone() async => (await pickContact())?.phone;
