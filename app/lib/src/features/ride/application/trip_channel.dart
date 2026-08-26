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

  bool _disposed = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  /// Every decoded frame (each carries a `type` and a stamped `sender_id`).
  Stream<Map<String, dynamic>> get messages => _controller.stream;

  Stream<Map<String, dynamic>> ofType(String type) =>
      messages.where((m) => m['type'] == type);

  Future<void> _connect() async {
    final token = await _tokens.access;
    if (_disposed) return;
    if (token == null) {
      // No token yet (e.g. a startup race) rather than a real auth failure
      // — worth retrying rather than leaving this trip's live tracking/
      // chat/calls dead for good.
      _scheduleReconnect();
      return;
    }
    final uri =
        Uri.parse('${AppConfig.wsBase}/v1/ws?token=$token&trip=$tripId');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    // `connect()` returns before the handshake actually succeeds or fails —
    // only reset the backoff once `ready` confirms the connection is real,
    // otherwise a persistently-down backend gets this reset on every single
    // attempt (before its own failure is even observed) and backoff never
    // grows past 1s, hammering the endpoint indefinitely instead of backing
    // off.
    ws.ready.then((_) {
      if (!_disposed) _reconnectAttempt = 0;
    }).catchError((_) {});
    ws.stream.listen(
      (raw) {
        try {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          _controller.add(m);
        } catch (_) {/* ignore malformed frames */}
      },
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );
  }

  /// Reconnects after a socket drop — an idle timeout from an intermediate
  /// proxy, a transient network blip, the phone's connectivity flapping —
  /// none of which should permanently kill live tracking/chat/calls for the
  /// rest of the trip the way a silent `onDone`/`onError` no-op used to
  /// (confirmed live: the driver marker would track a handful of GPS pings
  /// then freeze for good once the socket quietly died). Backoff grows with
  /// consecutive failures, capped, so a genuinely down backend isn't
  /// hammered.
  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final attempt = _reconnectAttempt++;
    final delaySecs = attempt >= 4 ? 15 : (1 << attempt); // 1,2,4,8,15,…
    _reconnectTimer = Timer(Duration(seconds: delaySecs), _connect);
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  void sendChat(String body) => _send({'type': 'chat', 'body': body});

  /// WebRTC signaling: kind = offer | answer | ice.
  void sendSignal(String kind, Object data) =>
      _send({'type': 'signal', 'kind': kind, 'data': data});

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
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
