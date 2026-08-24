import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/api_client.dart';
import '../../ride/domain/models.dart';
import '../domain/models.dart';

class DeliveryRepository {
  DeliveryRepository(this._api);

  final ApiClient _api;

  Future<DeliveryEstimate> estimate({
    required LatLng origin,
    required LatLng dest,
    required ParcelSize size,
    bool fragile = false,
  }) async {
    final res = await _api.post(
      '/v1/delivery/estimate',
      body: {
        'origin': {'lat': origin.latitude, 'lng': origin.longitude},
        'dest': {'lat': dest.latitude, 'lng': dest.longitude},
        'size_tier': size.wire,
        'fragile': fragile,
      },
    );
    return DeliveryEstimate.fromJson(res as Map<String, dynamic>);
  }

  /// Books a parcel; the backend creates a trackable `delivery` trip and
  /// hands back the recipient's proof-of-delivery OTP (needed later at
  /// drop-off, since `POST /v1/delivery/parcels/{id}/deliver` requires it —
  /// there's no other way to complete a delivery). The response is a
  /// `{trip, delivery_otp, delivery_fee, cod_amount}` wrapper, not a bare
  /// trip, so this can't just reuse `Trip.fromJson(res)` directly.
  Future<ParcelBooking> book(ParcelDraft draft) async {
    final res =
        await _api.post('/v1/delivery/parcels', body: draft.bookBody())
            as Map<String, dynamic>;
    return ParcelBooking(
      trip: Trip.fromJson(res['trip'] as Map<String, dynamic>),
      deliveryOtp: res['delivery_otp'] as String?,
    );
  }
}

final deliveryRepositoryProvider = Provider<DeliveryRepository>((ref) {
  return DeliveryRepository(ref.watch(apiClientProvider));
});
