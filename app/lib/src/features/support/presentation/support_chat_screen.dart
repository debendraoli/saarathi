import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/haptics.dart';
import '../../../shared/widgets/common.dart';
import '../data/support_repository.dart';
import '../domain/models.dart';

/// A rider/driver's own support thread — plain persisted messages with
/// staff, polled every few seconds (matches the SOS console's own polling
/// cadence; a support reply isn't time-critical enough to need a live
/// WebSocket channel).
class SupportChatScreen extends ConsumerStatefulWidget {
  const SupportChatScreen({super.key});

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
      if (_scroll.hasClients) {
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
      await ref.read(supportRepositoryProvider).send(body);
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
