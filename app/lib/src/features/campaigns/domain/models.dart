import '../../ride/domain/models.dart' show asDouble;

/// A platform-wide, staff-created promotion — `GET /v1/campaigns/active`.
/// Rider-facing offers only (this is what the home-screen banner shows);
/// redemption is automatic, no code entry needed.
class Offer {
  const Offer({
    required this.code,
    required this.title,
    required this.kind,
    required this.value,
    required this.minFare,
    this.maxDiscount,
  });

  final String code;
  final String title;
  final String kind; // percent | flat
  final double value;
  final double minFare;
  final double? maxDiscount;

  /// A short, human-readable discount line for the banner, e.g.
  /// "20% off, up to NPR 100" or "NPR 50 off your ride".
  String get discountLine {
    if (kind == 'percent') {
      final cap = maxDiscount;
      return cap == null
          ? '${value.toStringAsFixed(0)}% off your ride'
          : '${value.toStringAsFixed(0)}% off, up to NPR ${cap.toStringAsFixed(0)}';
    }
    return 'NPR ${value.toStringAsFixed(0)} off your ride';
  }

  factory Offer.fromJson(Map<String, dynamic> j) => Offer(
        code: j['code'] as String,
        title: (j['title'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'flat',
        value: asDouble(j['value']),
        minFare: asDouble(j['min_fare']),
        maxDiscount:
            j['max_discount'] == null ? null : asDouble(j['max_discount']),
      );
}
