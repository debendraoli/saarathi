import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/app_config.dart';
import '../../../core/storage/token_store.dart';
import '../domain/models.dart';

/// Live driver position over the trip-scoped WebSocket
/// (`/v1/ws?token&trip`). Emits each `{type:"location"}` message the backend
/// fans out. Silent until a driver is assigned and starts posting location.
final tripLocationProvider =
    StreamProvider.autoDispose.family<LatLng, String>((ref, tripId) async* {
  final token = await ref.watch(tokenStoreProvider).access;
  if (token == null) return;

  final uri = Uri.parse('${AppConfig.wsBase}/v1/ws?token=$token&trip=$tripId');
  final channel = WebSocketChannel.connect(uri);
  ref.onDispose(() => channel.sink.close());

  await for (final raw in channel.stream) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      if (data['type'] == 'location') {
        yield LatLng(asDouble(data['lat']), asDouble(data['lng']));
      }
    } catch (_) {
      // Ignore non-location / malformed frames.
    }
  }
});
