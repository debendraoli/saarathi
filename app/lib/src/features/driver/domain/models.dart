import '../../ride/domain/models.dart';

/// A dispatch offer shown to an online driver (short TTL; accept/decline).
class DriverOffer {  const DriverOffer({
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
  const DriverKyc({required this.status, this.uploadedKinds = const {}, this.rejectionReason});

  final KycStatus status;
  final Set<String> uploadedKinds;
  final String? rejectionReason;

  factory DriverKyc.fromJson(Map<String, dynamic> j) {
    final driver = j['driver'] as Map<String, dynamic>?;
    final docs = (j['documents'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    return DriverKyc(
      status: KycStatus.fromWire(driver?['kyc_status'] as String?),
      uploadedKinds: docs.map((d) => d['kind'] as String).toSet(),
      rejectionReason: driver?['rejection_reason'] as String?,
    );
  }
}
