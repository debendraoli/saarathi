import 'package:latlong2/latlong.dart';

import '../../ride/domain/models.dart';

/// A dispatch offer shown to an online driver (short TTL; accept/decline).
class DriverOffer {
  const DriverOffer({
    required this.tripId,
    required this.grossFare,
    required this.finalFare,
    required this.vehicleClass,
    required this.origin,
    required this.dest,
    this.distanceKm,
    this.expiresAt,
    this.pricingMode = 'instant',
    this.askFare,
    this.maxCounter,
  });

  final String tripId;
  final double grossFare;
  final double finalFare;
  final String vehicleClass;
  final LatLng origin;
  final LatLng dest;
  final double? distanceKm;
  final DateTime? expiresAt;

  /// 'instant' (accept at [finalFare]) or 'bid' (accept/counter [askFare]
  /// instead — see `routes::bidding` server-side).
  final String pricingMode;
  final double? askFare;

  /// The most this driver may counter-bid — the same legal-cap-clamped
  /// ceiling `POST /v1/rides/{id}/bid` enforces server-side (see
  /// `saarathi-rides::routes::dispatch::my_offers`). `null` outside bid
  /// mode. UI must use this rather than re-deriving a ratio locally — a
  /// client-side guess here previously let the counter-bid slider offer
  /// values the server would always reject.
  final double? maxCounter;

  bool get isBidding => pricingMode == 'bid';

  /// Driver keeps ≥ 90% (10% commission + 1% accident fund come off the top).
  double get netEarning => finalFare * 0.89;

  factory DriverOffer.fromJson(Map<String, dynamic> j) => DriverOffer(
        tripId: j['trip_id'] as String,
        grossFare: asDouble(j['gross_fare']),
        finalFare: asDouble(j['final_fare']),
        vehicleClass: (j['vehicle_class'] as String?) ?? 'two_wheeler',
        origin: LatLng(asDouble(j['origin_lat']), asDouble(j['origin_lng'])),
        dest: LatLng(asDouble(j['dest_lat']), asDouble(j['dest_lng'])),
        distanceKm:
            j['distance_km'] == null ? null : asDouble(j['distance_km']),
        expiresAt: j['expires_at'] == null
            ? null
            : DateTime.tryParse(j['expires_at'] as String),
        pricingMode: (j['pricing_mode'] as String?) ?? 'instant',
        askFare: j['ask_fare'] == null ? null : asDouble(j['ask_fare']),
        maxCounter:
            j['max_counter'] == null ? null : asDouble(j['max_counter']),
      );
}

/// KYC document kinds the driver must submit (order = display order).
enum DocKind {
  profilePhoto('profile_photo'),
  citizenshipFront('citizenship_front'),
  citizenshipBack('citizenship_back'),
  license('license'),
  bluebook('bluebook'),
  vehiclePhoto('vehicle_photo'),
  insurance('insurance');

  const DocKind(this.wire);
  final String wire;
}

enum KycStatus {
  pending,
  underReview,
  approved,
  rejected,
  none;

  static KycStatus fromWire(String? s) {
    switch (s) {
      case 'pending':
        return KycStatus.pending;
      case 'under_review':
        return KycStatus.underReview;
      case 'approved':
        return KycStatus.approved;
      case 'rejected':
        return KycStatus.rejected;
      default:
        return KycStatus.none;
    }
  }
}

/// Driver verification snapshot from GET /v1/driver/status.
class DriverKyc {
  const DriverKyc(
      {required this.status,
      this.uploadedKinds = const {},
      this.rejectionReason,
      this.serviceTypes = const {'ride'}});

  final KycStatus status;
  final Set<String> uploadedKinds;
  final String? rejectionReason;

  /// Which job types this driver accepts — set at KYC, editable later from
  /// the admin dashboard (see `PATCH /v1/admin/drivers/{id}/service-types`).
  final Set<String> serviceTypes;

  factory DriverKyc.fromJson(Map<String, dynamic> j) {
    final driver = j['driver'] as Map<String, dynamic>?;
    final docs =
        (j['documents'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final types = (driver?['service_types'] as List?)?.cast<String>().toSet();
    return DriverKyc(
      status: KycStatus.fromWire(driver?['kyc_status'] as String?),
      uploadedKinds: docs.map((d) => d['kind'] as String).toSet(),
      rejectionReason: driver?['rejection_reason'] as String?,
      serviceTypes: types == null || types.isEmpty ? const {'ride'} : types,
    );
  }
}
