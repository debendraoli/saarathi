import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.klass,
    required this.read,
    this.body,
    this.createdAt,
  });

  final String id;
  final String title;
  final String klass;
  final bool read;
  final String? body;
  final DateTime? createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        klass: (j['class'] as String?) ?? 'info',
        read: j['read_at'] != null,
        body: j['body'] as String?,
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
      );
}

class Inbox {
  const Inbox({required this.unread, required this.items});
  final int unread;
  final List<AppNotification> items;
}

class NotificationsRepository {
  NotificationsRepository(this._api);
  final ApiClient _api;

  Future<Inbox> inbox() async {
    final res = await _api.get('/v1/notifications') as Map<String, dynamic>;
    final items =
        (res['items'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return Inbox(
      unread: (res['unread'] as num?)?.toInt() ?? 0,
      items: items.map(AppNotification.fromJson).toList(),
    );
  }

  Future<void> markRead(String id) => _api.post('/v1/notifications/$id/read');
  Future<void> markAllRead() => _api.post('/v1/notifications/read-all');
}

final notificationsRepositoryProvider =
    Provider<NotificationsRepository>((ref) {
  return NotificationsRepository(ref.watch(apiClientProvider));
});

final inboxProvider = FutureProvider.autoDispose<Inbox>((ref) {
  return ref.watch(notificationsRepositoryProvider).inbox();
});
