import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../domain/models.dart';
import 'trip_channel.dart';

/// Live driver position over the shared trip channel. Silent until a driver is
/// assigned and starts posting `location` frames.
final tripLocationProvider =
    StreamProvider.autoDispose.family<LatLng, String>((ref, tripId) {
  final channel = ref.watch(tripChannelProvider(tripId));
  return channel
      .ofType('location')
      .map((m) => LatLng(asDouble(m['lat']), asDouble(m['lng'])));
});
