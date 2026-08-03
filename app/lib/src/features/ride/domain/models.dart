import 'package:latlong2/latlong.dart';

double asDouble(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

enum VehicleClass {
  twoWheeler('two_wheeler', 'motorcycle'),
  threeWheeler('three_wheeler', 'auto'),
  fourWheeler('four_wheeler', 'auto');

  const VehicleClass(this.wire, this.profile);
  final String wire;
  final String profile;
}

/// A named location. Many Dang pickups are landmark-based, not precise pins, so
/// [label] carries the human reference ("near Ghantaghar").
class Place {
  const Place({required this.point, this.label = ''});
  final LatLng point;
  final String label;

  Map<String, dynamic> toJson() =>
      {'lat': point.latitude, 'lng': point.longitude};
}

/// Everything needed to price + book a ride, passed between screens.
class RideDraft {
  const RideDraft({
    required this.pickup,
    required this.destination,
    this.vehicleClass = VehicleClass.twoWheeler,
    this.paymentMethod = 'cash',
  });

  final Place pickup;
  final Place destination;
  final VehicleClass vehicleClass;
  final String paymentMethod;

  RideDraft copyWith({VehicleClass? vehicleClass, String? paymentMethod}) =>
      RideDraft(
        pickup: pickup,
        destination: destination,
        vehicleClass: vehicleClass ?? this.vehicleClass,
        paymentMethod: paymentMethod ?? this.paymentMethod,
      );
}

class FareEstimate {
  const FareEstimate({
    required this.distanceKm,
    required this.durationSecs,
    required this.grossFare,
    required this.finalFare,
    required this.surgeMultiplier,
    required this.currency,
    this.routeSource = '',
  });

  final double distanceKm;
  final int durationSecs;
  final double grossFare;
  final double finalFare;
  final double surgeMultiplier;
  final String currency;
  final String routeSource;

  int get durationMins => (durationSecs / 60).ceil();

  factory FareEstimate.fromJson(Map<String, dynamic> j) => FareEstimate(
        distanceKm: asDouble(j['distance_km']),
        durationSecs: (j['duration_secs'] as num?)?.toInt() ?? 0,
        grossFare: asDouble(j['gross_fare']),
        finalFare: asDouble(j['final_fare']),
        surgeMultiplier: asDouble(j['surge_multiplier']),
        currency: (j['currency'] as String?) ?? 'NPR',
        routeSource: (j['route_source'] as String?) ?? '',
      );
}

/// Trip lifecycle mirrored from the backend state machine.
enum TripStatus {
  requested,
  searching,
  accepted,
  arriving,
  inProgress,
  completed,
  cancelled,
  noDriver,
  unknown;

  static TripStatus fromWire(String? s) {
    switch (s) {
      case 'requested':
        return TripStatus.requested;
      case 'searching':
        return TripStatus.searching;
      case 'accepted':
        return TripStatus.accepted;
      case 'arriving':
        return TripStatus.arriving;
      case 'in_progress':
        return TripStatus.inProgress;
      case 'completed':
        return TripStatus.completed;
      case 'cancelled':
        return TripStatus.cancelled;
      case 'no_driver':
        return TripStatus.noDriver;
      default:
        return TripStatus.unknown;
    }
  }
}

class Trip {
  const Trip({
    required this.id,
    required this.status,
    required this.origin,
    required this.dest,
    required this.finalFare,
    this.driverId,
    this.vehicleClass,
    this.tripType,
    this.distanceKm = 0,
    this.createdAt,
  });

  final String id;
  final TripStatus status;
  final LatLng origin;
  final LatLng dest;
  final double finalFare;
  final String? driverId;
  final String? vehicleClass;
  final String? tripType;
  final double distanceKm;
  final DateTime? createdAt;

  bool get isActive => const {
        TripStatus.searching,
        TripStatus.requested,
        TripStatus.accepted,
        TripStatus.arriving,
        TripStatus.inProgress,
      }.contains(status);

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        id: j['id'] as String,
        status: TripStatus.fromWire(j['status'] as String?),
        origin: LatLng(asDouble(j['origin_lat']), asDouble(j['origin_lng'])),
        dest: LatLng(asDouble(j['dest_lat']), asDouble(j['dest_lng'])),
        finalFare: asDouble(j['final_fare']),
        driverId: j['driver_id'] as String?,
        vehicleClass: j['vehicle_class'] as String?,
        tripType: j['trip_type'] as String?,
        distanceKm: asDouble(j['distance_km']),
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
      );
}
