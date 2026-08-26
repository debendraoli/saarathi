import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../../marketplace/data/marketplace_repository.dart';
import '../../ride/application/ride_controller.dart';
import '../data/support_repository.dart';
import '../domain/models.dart';

/// Preset trip/order to reference — passed via `context.push(Routes.support,
/// extra: SupportContextArgs(...))` from a trip/order details page's "Get
/// help" button, so the resulting thread already carries what the issue is
/// about instead of relying on the rider to describe it in free text.
class SupportContextArgs {
  const SupportContextArgs({this.tripId, this.orderId});
  final String? tripId;
  final String? orderId;
}

/// A rider/driver's own support thread — plain persisted messages with
/// staff, polled every few seconds (matches the SOS console's own polling
/// cadence; a support reply isn't time-critical enough to need a live
/// WebSocket channel).
class SupportChatScreen extends ConsumerStatefulWidget {
  const SupportChatScreen({super.key, this.tripId, this.orderId});

  /// When set (reached via a trip/order's "Get help" button), every message
  /// sent during this screen's lifetime is tagged with it — see
  /// `SupportContextArgs`. `null` for the plain menu-entry "Support" path,
  /// same as before.
  final String? tripId;
  final String? orderId;

  @override
  ConsumerState<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends ConsumerState<SupportChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      ref.invalidate(supportThreadProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `dispose()` cancels `_poll` but also disposes `_scroll` itself — a
      // callback queued just before teardown must check `mounted`, not just
      // `hasClients`, or it can call into an already-disposed controller.
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    _input.clear();
    try {
      await ref.read(supportRepositoryProvider).send(
            body,
            tripId: widget.tripId,
            orderId: widget.orderId,
          );
      // The user can back out of the chat while this send is in flight —
      // `ref.invalidate`/touching state on a disposed ConsumerState throws.
      if (!mounted) return;
      ref.invalidate(supportThreadProvider);
      _scrollToEnd();
    } on ApiException catch (e) {
      Haptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.isNetwork ? AppL10n.of(context).errorNetwork : e.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(supportThreadProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.supportTitle)),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.tripId != null) _TripContextCard(tripId: widget.tripId!),
            if (widget.orderId != null) _OrderContextCard(orderId: widget.orderId!),
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => ErrorRetry(
                  message: l.errorNetwork,
                  onRetry: () => ref.invalidate(supportThreadProvider),
                ),
                data: (messages) {
                  if (messages.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(l.supportEmptyState, textAlign: TextAlign.center),
                      ),
                    );
                  }
                  _scrollToEnd();
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => _Bubble(message: messages[i]),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(hintText: l.supportChatHint),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: scheme.primary),
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "About: Ride, NPR 350, 26 Aug" — shown above the chat so staff (once
/// they have their own thread UI reading this same `trip_id`) and the rider
/// alike can see at a glance what this conversation is about, instead of
/// relying on free text to describe it. Quietly renders nothing while the
/// trip is still loading rather than a placeholder card flashing in.
class _TripContextCard extends ConsumerWidget {
  const _TripContextCard({required this.tripId});
  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final trip = ref.watch(tripDetailsProvider(tripId)).valueOrNull;
    if (trip == null) return const SizedBox.shrink();
    final date = trip.createdAt?.toLocal();
    final dateLabel = date == null
        ? ''
        : ' · ${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return _ContextCard(
      icon: Icons.two_wheeler_rounded,
      label: '${l.supportAboutTrip} · NPR ${trip.finalFare.toStringAsFixed(0)}$dateLabel',
    );
  }
}

class _OrderContextCard extends ConsumerWidget {
  const _OrderContextCard({required this.orderId});
  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(orderProvider(orderId)).valueOrNull;
    if (order == null) return const SizedBox.shrink();
    return _ContextCard(
      icon: Icons.inventory_2_rounded,
      label: '${order.merchantName} · NPR ${order.total.toStringAsFixed(0)}',
    );
  }
}

class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        color: scheme.surfaceContainerHighest,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '${l.supportAbout}: ',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                    ),
                    TextSpan(text: label, style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final SupportMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = !message.fromStaff;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: mine ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.body,
          style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface),
        ),
      ),
    );
  }
}
