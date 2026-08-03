import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Cache-through helper for list endpoints: fetch fresh, persist the raw JSON,
/// and fall back to the last cached copy when the network fails (offline-first,
/// for Nepal's patchy connectivity). Reconcile = just fetch again when online.
Future<List<T>> cacheThroughList<T>({
  required SharedPreferences prefs,
  required String key,
  required Future<dynamic> Function() fetch,
  required T Function(Map<String, dynamic>) parse,
}) async {
  try {
    final res = await fetch();
    final list = (res as List).cast<Map<String, dynamic>>();
    await prefs.setString(key, jsonEncode(list));
    return list.map(parse).toList();
  } catch (_) {
    final cached = prefs.getString(key);
    if (cached != null) {
      final list = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
      return list.map(parse).toList();
    }
    rethrow;
  }
}
