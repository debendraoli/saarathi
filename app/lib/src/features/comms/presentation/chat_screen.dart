import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:saarathi/l10n/app_localizations.dart';

import '../../auth/application/auth_controller.dart';
import '../../ride/application/ride_controller.dart';
import '../../ride/application/trip_channel.dart';
import '../../ride/domain/models.dart' show TripStatus;

class _Msg {
  const _Msg(this.body, this.mine);
  final String body;
  final bool mine;
}

/// Masked in-app chat over the trip channel — no real phone numbers shared.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.tripId});
  final String tripId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [];
  StreamSubscription<Map<String, dynamic>>? _sub;

  // A quick-reply chip has no disable-after-tap and the message list is
  // only populated from the channel's own echo (not appended locally), so
  // a fast double-tap — common enough under motion in a vehicle — sent (and
  // rendered) the same canned message twice. Debounce identical sends
  // within a short window instead.
  String? _lastSentBody;
  DateTime? _lastSentAt;

  @override
  void initState() {
    super.initState();
    final myId = ref.read(authControllerProvider).user?.id;
    final channel = ref.read(tripChannelProvider(widget.tripId));
    _sub = channel.ofType('chat').listen((m) {
      final body = (m['body'] as String?)?.trim() ?? '';
      if (body.isEmpty) return;
      setState(() => _messages.add(_Msg(body, m['sender_id'] == myId)));
      _scrollToEnd();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `dispose()` cancels `_sub` but the ScrollController itself is also
      // disposed there — a callback queued just before teardown must check
      // `mounted` (not just `hasClients`) or it can call `.hasClients` on an
      // already-disposed controller.
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send([String? text]) {
    final body = (text ?? _input.text).trim();
    if (body.isEmpty) return;
    final now = DateTime.now();
    if (body == _lastSentBody &&
        _lastSentAt != null &&
        now.difference(_lastSentAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastSentBody = body;
    _lastSentAt = now;
    ref.read(tripChannelProvider(widget.tripId)).sendChat(body);
    if (text == null) _input.clear();
    // The message returns via the fan-out echo, so we don't append locally.
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final myId = ref.watch(authControllerProvider).user?.id;
    final trip = ref.watch(tripStreamProvider(widget.tripId)).value;
    final iAmDriver = myId != null && myId == trip?.driverId;
    // Neither side had anything watching trip status before — a cancelled
    // or completed trip left the chat fully open with no indication the
    // conversation was effectively over.
    final tripEnded = trip != null &&
        (trip.status == TripStatus.cancelled ||
            trip.status == TripStatus.completed);
    final quickReplies = iAmDriver
        ? [l.quickReplyImArriving, l.quickReplyRunningLate]
        : [
            l.quickReplyImAtLocation,
            l.quickReplyComingDown,
            l.quickReplyPleaseWait
          ];

    return Scaffold(
      appBar: AppBar(title: Text(l.chatTitle)),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      l.chatSayHello,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _Bubble(msg: _messages[i]),
                  ),
          ),
          if (tripEnded)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(
                  l.chatEnded,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: quickReplies.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ActionChip(
                  label: Text(quickReplies[i]),
                  onPressed: () => _send(quickReplies[i]),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration:
                            InputDecoration(hintText: l.chatMessageHint),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _send,
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg});
  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: msg.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: msg.mine ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          msg.body,
          style:
              TextStyle(color: msg.mine ? scheme.onPrimary : scheme.onSurface),
        ),
      ),
    );
  }
}
