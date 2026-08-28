import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/prefs.dart';
import '../../../shared/paged_notifier.dart';
import '../../../shared/provider_retry.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.klass,
    required this.read,
    this.body,
    this.link,
    this.createdAt,
  });

  final String id;
  final String title;
  final String klass;
  final bool read;
  final String? body;
  final String? link;
  final DateTime? createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        klass: (j['class'] as String?) ?? 'info',
        read: j['read_at'] != null,
        body: j['body'] as String?,
        link: j['link'] as String?,
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
      );
}

class Inbox {
  const Inbox({required this.unread, required this.items});
  final int unread;
  final List<AppNotification> items;
}

class NotificationsRepository {
  NotificationsRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;

  static const _cacheKey = 'cache.notifications';

  Future<Inbox> inbox() async {
    Map<String, dynamic> res;
    try {
      res = await _api.get('/v1/notifications') as Map<String, dynamic>;
      await _prefs.setString(_cacheKey, jsonEncode(res));
    } catch (e) {
      final cached = _prefs.getString(_cacheKey);
      if (cached == null) rethrow;
      res = jsonDecode(cached) as Map<String, dynamic>;
    }
    final items =
        (res['items'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return Inbox(
      unread: (res['unread'] as num?)?.toInt() ?? 0,
      items: items.map(AppNotification.fromJson).toList(),
    );
  }

  Future<void> markRead(String id) => _api.post('/v1/notifications/$id/read');
  Future<void> markAllRead() => _api.post('/v1/notifications/read-all');

  /// One page of notifications for the inbox screen's infinite scroll — a
  /// plain live fetch, not the cached-whole-inbox [inbox] above (which stays
  /// as-is for the unread badge and the notification-tap-nav lookup, which
  /// just need "the recent set", not a scrollable list).
  Future<List<AppNotification>> inboxPage(
      {required int limit, required int offset}) async {
    final res = await _api.get('/v1/notifications', query: {
      'limit': limit.toString(),
      'offset': offset.toString(),
    }) as Map<String, dynamic>;
    final items =
        (res['items'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return items.map(AppNotification.fromJson).toList();
  }
}

final notificationsRepositoryProvider =
    Provider<NotificationsRepository>((ref) {
  return NotificationsRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

final inboxProvider = FutureProvider.autoDispose<Inbox>((ref) {
  return ref.watch(notificationsRepositoryProvider).inbox();
}, retry: shortNetworkRetry);

/// Infinite-scroll version of [inboxProvider] for the notifications screen's
/// actual list rendering — [inboxProvider] above stays for the unread badge
/// and notification-tap navigation lookup.
class InboxPaged extends PagedNotifier<AppNotification> {
  @override
  Future<List<AppNotification>> fetchPage(int offset, int limit) => ref
      .read(notificationsRepositoryProvider)
      .inboxPage(limit: limit, offset: offset);
}

final inboxPagedProvider =
    AsyncNotifierProvider.autoDispose<InboxPaged, PagedState<AppNotification>>(
        InboxPaged.new);
