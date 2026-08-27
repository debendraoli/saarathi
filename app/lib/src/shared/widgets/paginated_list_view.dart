import 'package:flutter/material.dart';

import '../paged_notifier.dart';

/// Scroll-triggered "load more" list for a [PagedState] — fires [onLoadMore]
/// once the scroll position gets within [loadMoreThreshold] of the bottom,
/// same trigger distance pattern as most infinite-scroll implementations
/// (loading the next page slightly before the user hits the literal end
/// keeps the list from ever visibly stalling on a blank gap).
///
/// Deliberately takes the already-fetched `state` plus a plain
/// `itemBuilder`/`separatorBuilder` rather than owning the fetch itself —
/// every screen's actual item type and card widget differs, but the
/// scroll-trigger/footer-spinner/error-retry mechanics are identical
/// everywhere, so only those are shared.
class PaginatedListView<T> extends StatefulWidget {
  const PaginatedListView({
    super.key,
    required this.state,
    required this.itemBuilder,
    required this.onLoadMore,
    this.separatorBuilder,
    this.padding,
    this.controller,
    this.loadMoreThreshold = 400,
  });

  final PagedState<T> state;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final Widget Function(BuildContext context, int index)? separatorBuilder;
  final VoidCallback onLoadMore;
  final EdgeInsets? padding;
  final ScrollController? controller;
  final double loadMoreThreshold;

  @override
  State<PaginatedListView<T>> createState() => _PaginatedListViewState<T>();
}

class _PaginatedListViewState<T> extends State<PaginatedListView<T>> {
  ScrollController? _ownController;
  ScrollController get _controller => widget.controller ?? _ownController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _ownController = ScrollController();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _ownController?.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    final remaining =
        _controller.position.maxScrollExtent - _controller.position.pixels;
    if (remaining < widget.loadMoreThreshold) widget.onLoadMore();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.state.items;
    final showFooter = widget.state.loading || widget.state.error != null;
    return ListView.separated(
      controller: _controller,
      padding: widget.padding,
      itemCount: items.length + (showFooter ? 1 : 0),
      separatorBuilder: (context, i) => i >= items.length - 1
          ? const SizedBox.shrink()
          : widget.separatorBuilder?.call(context, i) ??
              const SizedBox.shrink(),
      itemBuilder: (context, i) {
        if (i >= items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: widget.state.error != null
                  ? TextButton(
                      onPressed: widget.onLoadMore,
                      child: const Text('Retry'),
                    )
                  : const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
            ),
          );
        }
        return widget.itemBuilder(context, items[i], i);
      },
    );
  }
}
