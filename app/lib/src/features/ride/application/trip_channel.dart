import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/app_config.dart';
import '../../../core/storage/token_store.dart';

/// One WebSocket per trip (`/v1/ws?token&trip`) multiplexing every message type
/// the backend fans out: `location`, `status`, `chat`, `presence`, and WebRTC
/// `signal`. Screens subscribe to [messages] and send via the typed helpers.
class TripChannel {
  TripChannel(this._tokens, this.tripId) {
    _connect();
  }

  final TokenStore _tokens;
  final String tripId;

  WebSocketChannel? _ws;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  /// Every decoded frame (each carries a `type` and a stamped `sender_id`).
  Stream<Map<String, dynamic>> get messages => _controller.stream;

  Stream<Map<String, dynamic>> ofType(String type) =>
      messages.where((m) => m['type'] == type);

  Future<void> _connect() async {
    final token = await _tokens.access;
    if (token == null) return;
    final uri =
        Uri.parse('${AppConfig.wsBase}/v1/ws?token=$token&trip=$tripId');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    ws.stream.listen(
      (raw) {
        try {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          _controller.add(m);
        } catch (_) {/* ignore malformed frames */}
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  void sendChat(String body) => _send({'type': 'chat', 'body': body});

  /// WebRTC signaling: kind = offer | answer | ice.
  void sendSignal(String kind, Object data) =>
      _send({'type': 'signal', 'kind': kind, 'data': data});

  void dispose() {
    _ws?.sink.close();
    _controller.close();
  }
}

/// Shared per-trip channel; stays alive while any screen (tracking, chat, call)
/// is watching it, and closes when the last one leaves.
final tripChannelProvider =
    Provider.autoDispose.family<TripChannel, String>((ref, tripId) {
  final channel = TripChannel(ref.watch(tokenStoreProvider), tripId);
  ref.onDispose(channel.dispose);
  // Keep the socket open briefly after the last listener to smooth screen hops.
  final link = ref.keepAlive();
  final timer = Timer(const Duration(seconds: 30), link.close);
  ref.onDispose(timer.cancel);
  return channel;
});
