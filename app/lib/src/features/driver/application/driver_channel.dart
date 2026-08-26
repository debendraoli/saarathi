import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/app_config.dart';
import '../../../core/storage/token_store.dart';

/// Receive-only WebSocket (`/v1/driver/ws?token`) connected for as long as
/// the driver is online, independent of any specific trip — used purely so
/// a new dispatch offer (`{"type": "offer", ...}`) reaches the driver the
/// instant it's created instead of waiting for the next 4s poll tick (see
/// `driverOffersProvider`, which listens to [ofType]('offer') as an
/// immediate-refresh trigger while the poll itself keeps running as the
/// safety net). Going online/offline/heartbeat still go over plain HTTP —
/// this socket never sends anything.
class DriverChannel {
  DriverChannel(this._tokens) {
    _connect();
  }

  final TokenStore _tokens;

  WebSocketChannel? _ws;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  bool _disposed = false;
  int _reconnectAttempt = 0;
  Timer? _reconnectTimer;

  Stream<Map<String, dynamic>> get messages => _controller.stream;

  Stream<Map<String, dynamic>> ofType(String type) =>
      messages.where((m) => m['type'] == type);

  Future<void> _connect() async {
    final token = await _tokens.access;
    if (_disposed) return;
    if (token == null) {
      _scheduleReconnect();
      return;
    }
    final uri = Uri.parse('${AppConfig.wsBase}/v1/driver/ws?token=$token');
    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    // See TripChannel._connect: `connect()` returns before the handshake
    // actually succeeds or fails, so only reset backoff once `ready`
    // confirms it — otherwise a persistently-down backend gets the reset on
    // every attempt and backoff never grows past 1s.
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

  /// Same reconnect-with-backoff as `TripChannel` — a dropped socket (idle
  /// timeout, network blip) shouldn't silently stop new offers from ever
  /// reaching this driver again for the rest of their online session.
  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final attempt = _reconnectAttempt++;
    final delaySecs = attempt >= 4 ? 15 : (1 << attempt); // 1,2,4,8,15,…
    _reconnectTimer = Timer(Duration(seconds: delaySecs), _connect);
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _ws?.sink.close();
    _controller.close();
  }
}

/// Connected only while the driver is online — mirrors `driverOffersProvider`'s
/// own online-gating, since there's nothing for this socket to do otherwise.
final driverChannelProvider = Provider.autoDispose<DriverChannel>((ref) {
  final channel = DriverChannel(ref.watch(tokenStoreProvider));
  ref.onDispose(channel.dispose);
  return channel;
});
