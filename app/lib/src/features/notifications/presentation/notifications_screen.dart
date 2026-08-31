import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/router/deep_links.dart';
import '../../../shared/widgets/common.dart';
import '../../../shared/widgets/paginated_list_view.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/notifications_repository.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final inbox = ref.watch(inboxPagedProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.notifications),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.read(notificationsRepositoryProvider).markAllRead();
              ref.invalidate(inboxProvider);
              ref.invalidate(inboxPagedProvider);
            },
            child: Text(l.markAllRead),
          ),
        ],
      ),
      body: inbox.when(
        loading: () => const SkeletonList(),
        error: (_, __) => ErrorRetry(
          message: l.errorNetwork,
          onRetry: () => ref.invalidate(inboxPagedProvider),
        ),
        data: (page) {
          if (page.items.isEmpty) {
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
            onRefresh: () => ref.read(inboxPagedProvider.notifier).refresh(),
            child: PaginatedListView<AppNotification>(
              state: page,
              onLoadMore: () =>
                  ref.read(inboxPagedProvider.notifier).loadMore(),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, n, i) {
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
                            ref.invalidate(inboxPagedProvider);
                          }
                          final link = n.link;
                          if (link == null) return;
                          if (!context.mounted) return;
                          final target = routeForDeepLink(Uri.parse(link));
                          if (target != null) {
                            context.push(target);
                          } else {
                            // The notification is now permanently marked
                            // read with nothing to show for the tap — the
                            // target trip/order/etc. no longer resolves
                            // (deleted, expired). Previously this was
                            // silent, indistinguishable from a broken tap.
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(l.notificationTargetGone)),
                            );
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
