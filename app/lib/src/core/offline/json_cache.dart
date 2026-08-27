import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Cache-through helper for list endpoints: fetch fresh, persist the raw JSON,
/// and fall back to the last cached copy when the network fails (offline-first,
/// for Nepal's patchy connectivity). Reconcile = just fetch again when online.
///
/// The cached copy carries no expiry of its own — it's used whenever the
/// network fetch fails, no matter how old it is, since stale data is still
/// more useful than none for an offline-tolerant app. [onStale], when given,
/// is called with the cache's save time whenever a fallback is actually
/// served, so a caller that wants to (e.g. "showing saved data from 2h ago")
/// can — this is opt-in, existing callers that ignore it are unaffected.
Future<List<T>> cacheThroughList<T>({
  required SharedPreferences prefs,
  required String key,
  required Future<dynamic> Function() fetch,
  required T Function(Map<String, dynamic>) parse,
  void Function(DateTime cachedAt)? onStale,
}) async {
  try {
    final res = await fetch();
    final list = (res as List).cast<Map<String, dynamic>>();
    await prefs.setString(
      key,
      jsonEncode({
        'savedAt': DateTime.now().toIso8601String(),
        'items': list,
      }),
    );
    return list.map(parse).toList();
  } catch (_) {
    final cached = prefs.getString(key);
    if (cached != null) {
      // A corrupt/legacy-shaped cache entry throwing here must not mask the
      // original network failure with a confusing new exception — surface
      // that original error instead, same as having no cache at all.
      try {
        final envelope = jsonDecode(cached) as Map<String, dynamic>;
        final list =
            (envelope['items'] as List).cast<Map<String, dynamic>>();
        final savedAt = DateTime.parse(envelope['savedAt'] as String);
        onStale?.call(savedAt);
        return list.map(parse).toList();
      } catch (_) {
        // fall through to rethrow the original network error below
      }
    }
    rethrow;
  }
}

/// Wipes every [cacheThroughList] entry (all keys share the `cache.` prefix
/// by convention). Call on sign-out — these caches are device-local and keyed
/// by endpoint, not by account, so without this a fallback-to-cache on the
/// *next* account's very first fetch (e.g. a token not yet propagated, a
/// transient network blip right after login) would silently serve the
/// previous account's data instead of failing or fetching fresh. Confirmed
/// live: this is exactly how a rider→merchant switch on the same device
/// briefly showed the merchant account as if it were the outgoing rider.
Future<void> clearAllCaches(SharedPreferences prefs) async {
  for (final key in prefs.getKeys()) {
    if (key.startsWith('cache.')) {
      await prefs.remove(key);
    }
  }
}
