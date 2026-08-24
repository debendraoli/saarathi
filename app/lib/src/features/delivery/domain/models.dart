import '../../ride/domain/models.dart';

enum ParcelSize {
  envelope('envelope', 'Envelope'),
  small('small', 'Small'),
  medium('medium', 'Medium');

  const ParcelSize(this.wire, this.label);
  final String wire;
  final String label;
}

class DeliveryEstimate {
  const DeliveryEstimate({
    required this.distanceKm,
    required this.durationSecs,
    required this.deliveryFee,
  });

  final double distanceKm;
  final int durationSecs;
  final double deliveryFee;

  int get durationMins => (durationSecs / 60).ceil();

  factory DeliveryEstimate.fromJson(Map<String, dynamic> j) => DeliveryEstimate(
        distanceKm: asDouble(j['distance_km']),
        durationSecs: (j['duration_secs'] as num?)?.toInt() ?? 0,
        deliveryFee: asDouble(j['delivery_fee']),
      );
}

class ParcelDraft {
  const ParcelDraft({
    required this.origin,
    required this.dest,
    required this.size,
    required this.recipientName,
    required this.recipientPhone,
    this.fragile = false,
    this.codAmount = 0,
    this.pickupNote,
    this.paymentMethod = 'cash',
  });

  final Place origin;
  final Place dest;
  final ParcelSize size;
  final String recipientName;
  final String recipientPhone;
  final bool fragile;
  final double codAmount;
  final String? pickupNote;
  final String paymentMethod;

  Map<String, dynamic> bookBody() => {
        'origin': origin.toJson(),
        'dest': dest.toJson(),
        'size_tier': size.wire,
        'recipient_name': recipientName,
        'recipient_phone': recipientPhone,
        'fragile': fragile,
        'cod_amount': codAmount,
        if (pickupNote != null && pickupNote!.isNotEmpty)
          'pickup_note': pickupNote,
        'payment_method': paymentMethod,
      };
}

/// Result of booking a parcel: the trackable trip, plus the proof-of-
/// delivery OTP the recipient will need to show the driver at drop-off
/// (`POST /v1/delivery/parcels/{id}/deliver` requires it — it's the only
/// way to complete a delivery, so losing this after booking would strand
/// the trip with no way to close it out).
class ParcelBooking {
  const ParcelBooking({required this.trip, this.deliveryOtp});
  final Trip trip;
  final String? deliveryOtp;
}
