import '../../ride/domain/models.dart';

/// A dispatch offer shown to an online driver (short TTL; accept/decline).
class DriverOffer {
  const DriverOffer({
    required this.tripId,
    required this.grossFare,
    required this.finalFare,
    required this.vehicleClass,
    this.distanceKm,
  });

  final String tripId;
  final double grossFare;
  final double finalFare;
  final String vehicleClass;
  final double? distanceKm;

  /// Driver keeps ≥ 90% (10% commission + 1% accident fund come off the top).
  double get netEarning => finalFare * 0.89;

  factory DriverOffer.fromJson(Map<String, dynamic> j) => DriverOffer(
        tripId: j['trip_id'] as String,
        grossFare: asDouble(j['gross_fare']),
        finalFare: asDouble(j['final_fare']),
        vehicleClass: (j['vehicle_class'] as String?) ?? 'two_wheeler',
        distanceKm: j['distance_km'] == null ? null : asDouble(j['distance_km']),
      );
}
