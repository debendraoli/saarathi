import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One page-fetching list's state: everything loaded so far, whether a
/// fetch is in flight, whether the backend has more, and the last error (if
/// any) — kept alongside `items` rather than replacing them, so a failed
/// "load more" doesn't blank out what's already on screen.
class PagedState<T> {
  const PagedState({
    this.items = const [],
    this.loading = false,
    this.hasMore = true,
    this.error,
  });

  final List<T> items;
  final bool loading;
  final bool hasMore;
  final Object? error;

  PagedState<T> copyWith({
    List<T>? items,
    bool? loading,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) =>
      PagedState(
        items: items ?? this.items,
        loading: loading ?? this.loading,
        hasMore: hasMore ?? this.hasMore,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Base for an offset-paginated list backed by a `GET ...?limit=&offset=`
/// endpoint. Subclasses only implement [fetchPage]; this handles the
/// initial load, appending subsequent pages, in-flight/duplicate-call
/// guarding, and the "hasMore" heuristic (a page shorter than [pageSize]
/// means there's nothing left).
abstract class PagedNotifier<T> extends AutoDisposeAsyncNotifier<PagedState<T>> {
  int get pageSize => 20;

  /// Fetch one page. `offset` is the number of items already loaded.
  Future<List<T>> fetchPage(int offset, int limit);

  @override
  Future<PagedState<T>> build() async {
    final first = await fetchPage(0, pageSize);
    return PagedState(items: first, hasMore: first.length >= pageSize);
  }

  /// Fetches the next page and appends it — a no-op if a fetch is already
  /// in flight or the last page came back short (nothing more to load).
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.loading || !current.hasMore) return;
    state = AsyncData(current.copyWith(loading: true, clearError: true));
    try {
      final next =
          await fetchPage(current.items.length, pageSize);
      state = AsyncData(current.copyWith(
        items: [...current.items, ...next],
        loading: false,
        hasMore: next.length >= pageSize,
      ));
    } catch (e) {
      // Keep whatever's already loaded on screen — only the "load more"
      // attempt failed, not the whole list.
      state = AsyncData(current.copyWith(loading: false, error: e));
    }
  }

  /// Re-fetches from the start (pull-to-refresh) — replaces `state` outright
  /// rather than patching it, same as any other provider's `ref.invalidate`.
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final first = await fetchPage(0, pageSize);
      return PagedState(items: first, hasMore: first.length >= pageSize);
    });
  }
}
