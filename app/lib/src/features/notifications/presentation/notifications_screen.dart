import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/deep_links.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/notifications_repository.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final inbox = ref.watch(inboxProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.notifications),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.read(notificationsRepositoryProvider).markAllRead();
              ref.invalidate(inboxProvider);
            },
            child: Text(l.markAllRead),
          ),
        ],
      ),
      body: inbox.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(inboxProvider),
        ),
        data: (data) {
          if (data.items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_off_rounded,
                    size: 48,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 12),
                  Text(l.noNotifications),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(inboxProvider),
            child: ListView.separated(
              itemCount: data.items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final n = data.items[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: n.read
                        ? Theme.of(context).colorScheme.surfaceContainerHighest
                        : Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(
                      _iconFor(n.klass),
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  title: Text(
                    n.title,
                    style: TextStyle(
                      fontWeight: n.read ? FontWeight.w400 : FontWeight.w700,
                    ),
                  ),
                  subtitle: n.body == null ? null : Text(n.body!),
                  onTap: (n.read && n.link == null)
                      ? null
                      : () async {
                          if (!n.read) {
                            await ref
                                .read(notificationsRepositoryProvider)
                                .markRead(n.id);
                            ref.invalidate(inboxProvider);
                          }
                          final link = n.link;
                          if (link == null) return;
                          final target = routeForDeepLink(Uri.parse(link));
                          if (target != null && context.mounted) {
                            context.push(target);
                          }
                        },
                );
              },
            ),
          );
        },
      ),
    );
  }

  IconData _iconFor(String klass) {
    if (klass.contains('trip') || klass.contains('ride')) {
      return Icons.local_taxi_rounded;
    }
    if (klass.contains('sos') || klass.contains('safety')) {
      return Icons.emergency_rounded;
    }
    if (klass.contains('payment') || klass.contains('wallet')) {
      return Icons.payments_rounded;
    }
    return Icons.notifications_rounded;
  }
}
