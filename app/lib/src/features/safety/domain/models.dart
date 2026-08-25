class TrustedContact {
  const TrustedContact({
    required this.id,
    required this.name,
    required this.phone,
  });

  final String id;
  final String name;
  final String phone;

  factory TrustedContact.fromJson(Map<String, dynamic> j) => TrustedContact(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String,
      );
}

enum RideIndexLevel { green, yellow, red }

/// A plain-language readout of the rider's own cancellation behaviour —
/// `GET /v1/ride-index`. The band matters more than the raw percentage:
/// this exists to reassure a normal rider, not hand them a precise score.
class RideIndex {
  const RideIndex({
    required this.totalTrips,
    required this.cancelledByYou,
    required this.cancellationRate,
    required this.level,
  });

  final int totalTrips;
  final int cancelledByYou;
  final double cancellationRate;
  final RideIndexLevel level;

  factory RideIndex.fromJson(Map<String, dynamic> j) => RideIndex(
        totalTrips: (j['total_trips'] as num?)?.toInt() ?? 0,
        cancelledByYou: (j['cancelled_by_you'] as num?)?.toInt() ?? 0,
        cancellationRate: (j['cancellation_rate'] as num?)?.toDouble() ?? 0,
        level: switch (j['level'] as String?) {
          'yellow' => RideIndexLevel.yellow,
          'red' => RideIndexLevel.red,
          _ => RideIndexLevel.green,
        },
      );
}
