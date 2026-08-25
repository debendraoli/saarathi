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

  @override
  bool operator ==(Object other) =>
      other is Place && other.point == point && other.label == label;

  @override
  int get hashCode => Object.hash(point, label);
}

/// Everything needed to price + book a ride, passed between screens.
class RideDraft {
  const RideDraft({
    required this.pickup,
    required this.destination,
    this.stops = const [],
    this.vehicleClass = VehicleClass.twoWheeler,
    this.paymentMethod = 'cash',
    this.pricingMode = 'instant',
    this.askFare,
    this.radiusKm,
    this.preferredDriverPhone,
  });

  final Place pickup;
  final Place destination;

  /// Optional intermediate stops (multi-stop rides), in visiting order.
  final List<Place> stops;
  final VehicleClass vehicleClass;
  final String paymentMethod;

  /// 'instant' (today's one-tap algorithmic-fare booking) or 'bid' (open a
  /// fare auction instead — see `BiddingScreen`).
  final String pricingMode;

  /// The rider's starting ask, bid mode only.
  final double? askFare;

  /// Starting dispatch search radius (km), overriding the service default —
  /// set on a "search wider" re-request after a no-driver cancellation.
  final double? radiusKm;

  /// Request this driver by phone first, before normal matching — only
  /// takes effect if they're a driver this rider has ridden with before
  /// (see the backend's `resolve_preferred_driver`); otherwise it's just
  /// ignored and the trip books normally.
  final String? preferredDriverPhone;

  /// Ordered path pickup → stops → destination (for maps and routing).
  List<LatLng> get path =>
      [pickup.point, for (final s in stops) s.point, destination.point];

  RideDraft copyWith({
    VehicleClass? vehicleClass,
    String? paymentMethod,
    String? pricingMode,
    double? askFare,
    double? radiusKm,
    String? preferredDriverPhone,
  }) =>
      RideDraft(
        pickup: pickup,
        destination: destination,
        stops: stops,
        vehicleClass: vehicleClass ?? this.vehicleClass,
        paymentMethod: paymentMethod ?? this.paymentMethod,
        pricingMode: pricingMode ?? this.pricingMode,
        askFare: askFare ?? this.askFare,
        radiusKm: radiusKm ?? this.radiusKm,
        preferredDriverPhone: preferredDriverPhone ?? this.preferredDriverPhone,
      );

  // Value equality so `fareEstimateProvider(draft)` — a Riverpod `.family`,
  // keyed by `==`/`hashCode` — reuses the same request across rebuilds
  // instead of treating every freshly-constructed-but-identical draft as a
  // new key and refetching (this bit us once already: an infinite refetch
  // loop, since a screen that rebuilds the draft on every build() otherwise
  // never converges).
  @override
  bool operator ==(Object other) =>
      other is RideDraft &&
      other.pickup == pickup &&
      other.destination == destination &&
      _sameStops(other.stops, stops) &&
      other.vehicleClass == vehicleClass &&
      other.paymentMethod == paymentMethod &&
      other.pricingMode == pricingMode &&
      other.askFare == askFare &&
      other.radiusKm == radiusKm;

  @override
  int get hashCode => Object.hash(
        pickup,
        destination,
        Object.hashAll(stops),
        vehicleClass,
        paymentMethod,
        pricingMode,
        askFare,
        radiusKm,
      );

  static bool _sameStops(List<Place> a, List<Place> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
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
    this.fareFloor = 0,
    this.fareCeiling = 0,
  });

  final double distanceKm;
  final int durationSecs;
  final double grossFare;
  final double finalFare;
  final double surgeMultiplier;
  final String currency;
  final String routeSource;

  /// Bounded bargaining band a bid-mode ask (or a driver's counter) must
  /// stay within — mirrors the backend's `Estimate::fare_floor/ceiling`.
  final double fareFloor;
  final double fareCeiling;

  int get durationMins => (durationSecs / 60).ceil();

  factory FareEstimate.fromJson(Map<String, dynamic> j) => FareEstimate(
        distanceKm: asDouble(j['distance_km']),
        durationSecs: (j['duration_secs'] as num?)?.toInt() ?? 0,
        grossFare: asDouble(j['gross_fare']),
        finalFare: asDouble(j['final_fare']),
        surgeMultiplier: asDouble(j['surge_multiplier']),
        currency: (j['currency'] as String?) ?? 'NPR',
        routeSource: (j['route_source'] as String?) ?? '',
        fareFloor: asDouble(j['fare_floor']),
        fareCeiling: asDouble(j['fare_ceiling']),
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
    this.riderId,
    this.driverId,
    this.vehicleClass,
    this.tripType,
    this.distanceKm = 0,
    this.createdAt,
    this.cancelReason,
    this.pricingMode = 'instant',
    this.askFare,
    this.searchRadiusKm,
    this.paymentMethod = 'cash',
    this.durationSecs,
    this.rated = false,
  });

  final String id;
  final TripStatus status;
  final LatLng origin;
  final LatLng dest;
  final double finalFare;
  final String? riderId;
  final String? driverId;
  final String? vehicleClass;
  final String? tripType;
  final double distanceKm;
  final DateTime? createdAt;
  final String? cancelReason;

  /// Route duration estimated once at booking time — a static fallback ETA
  /// for before a driver's live position is available to route a real one
  /// from (see `tripEtaProvider`).
  final int? durationSecs;

  /// 'instant' (default) or 'bid' — see `BiddingScreen`.
  final String pricingMode;

  /// The rider's current asking price, bid mode only.
  final double? askFare;

  /// The starting dispatch radius (km) actually used for this trip, if it
  /// overrode the service default — set on a "search wider" re-request.
  final double? searchRadiusKm;

  final String paymentMethod;

  /// Whether the signed-in user has already rated this trip — from the
  /// trip list only (`GET /v1/rides`); not present on a single trip fetch.
  final bool rated;

  bool get isBidding => pricingMode == 'bid';

  bool get noDriverFound =>
      status == TripStatus.cancelled && cancelReason == 'no_driver_available';

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
        riderId: j['rider_id'] as String?,
        driverId: j['driver_id'] as String?,
        vehicleClass: j['vehicle_class'] as String?,
        tripType: j['trip_type'] as String?,
        distanceKm: asDouble(j['distance_km']),
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
        cancelReason: j['cancel_reason'] as String?,
        pricingMode: (j['pricing_mode'] as String?) ?? 'instant',
        askFare: j['ask_fare'] == null ? null : asDouble(j['ask_fare']),
        searchRadiusKm: j['search_radius_km'] == null
            ? null
            : asDouble(j['search_radius_km']),
        paymentMethod: (j['payment_method'] as String?) ?? 'cash',
        durationSecs: j['duration_secs'] == null
            ? null
            : (j['duration_secs'] as num).toInt(),
        rated: (j['rated'] as bool?) ?? false,
      );
}

/// Distance + duration between two points, from `POST /v1/rides/route` (the
/// same endpoint the map polyline geometry comes from) — used for a live,
/// recomputable ETA rather than the trip's static booking-time estimate.
class RouteEta {
  const RouteEta({required this.distanceKm, required this.durationSecs});
  final double distanceKm;
  final int durationSecs;

  int get durationMins => (durationSecs / 60).ceil();
}

/// Self-service lifetime ride stats — `GET /v1/rides/mine/stats`.
class RiderStats {
  const RiderStats({
    required this.totalRides,
    required this.completedRides,
    required this.cancelledRides,
    required this.totalSpend,
    required this.totalDistanceKm,
    this.avgRating,
    required this.ratingCount,
  });

  final int totalRides;
  final int completedRides;
  final int cancelledRides;
  final double totalSpend;
  final double totalDistanceKm;

  /// The rating the rider has *received* from drivers, not given.
  final double? avgRating;
  final int ratingCount;

  factory RiderStats.fromJson(Map<String, dynamic> j) => RiderStats(
        totalRides: (j['total_rides'] as num?)?.toInt() ?? 0,
        completedRides: (j['completed_rides'] as num?)?.toInt() ?? 0,
        cancelledRides: (j['cancelled_rides'] as num?)?.toInt() ?? 0,
        totalSpend: asDouble(j['total_spend']),
        totalDistanceKm: asDouble(j['total_distance_km']),
        avgRating: j['avg_rating'] == null ? null : asDouble(j['avg_rating']),
        ratingCount: (j['rating_count'] as num?)?.toInt() ?? 0,
      );
}

/// One "complete N rides today" driver campaign and progress toward it —
/// `GET /v1/rides/driver/today`. The bonus itself is granted automatically
/// server-side on the trip that crosses [target]; this is purely
/// informational for the home-screen goal card.
class DriverGoal {
  const DriverGoal({
    required this.campaignId,
    required this.title,
    required this.target,
    required this.rewardKind,
    required this.rewardValue,
    required this.achieved,
  });

  final String campaignId;
  final String title;
  final int target;
  final String rewardKind; // percent | flat
  final double rewardValue;
  final bool achieved;

  factory DriverGoal.fromJson(Map<String, dynamic> j) => DriverGoal(
        campaignId: j['campaign_id'] as String,
        title: (j['title'] as String?) ?? '',
        target: (j['target'] as num?)?.toInt() ?? 0,
        rewardKind: (j['reward_kind'] as String?) ?? 'flat',
        rewardValue: asDouble(j['reward_value']),
        achieved: (j['achieved'] as bool?) ?? false,
      );
}

class DriverGoals {
  const DriverGoals({required this.ridesToday, required this.goals});
  final int ridesToday;
  final List<DriverGoal> goals;

  factory DriverGoals.fromJson(Map<String, dynamic> j) => DriverGoals(
        ridesToday: (j['rides_today'] as num?)?.toInt() ?? 0,
        goals: ((j['goals'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(DriverGoal.fromJson)
            .toList(),
      );
}

/// One bucket of a driver's earnings history — `GET /v1/rides/driver/earnings`.
class EarningsBucket {
  const EarningsBucket({
    required this.start,
    required this.total,
    required this.trips,
  });
  final DateTime start;
  final double total;
  final int trips;

  factory EarningsBucket.fromJson(Map<String, dynamic> j) => EarningsBucket(
        start: DateTime.tryParse((j['start'] as String?) ?? '') ?? DateTime.now(),
        total: asDouble(j['total']),
        trips: (j['trips'] as num?)?.toInt() ?? 0,
      );
}

/// A driver's own earnings, gap-filled and bucketed by day/week/month —
/// `GET /v1/rides/driver/earnings?period=day|week|month`. [current]/
/// [previous] and [changePct] are derived client-side from the last two
/// buckets rather than computed server-side — one response shape covers
/// both the trend indicator and the recent-history list.
class DriverEarnings {
  const DriverEarnings({required this.period, required this.buckets});
  final String period;
  final List<EarningsBucket> buckets;

  EarningsBucket? get current => buckets.isEmpty ? null : buckets.last;
  EarningsBucket? get previous =>
      buckets.length < 2 ? null : buckets[buckets.length - 2];

  /// `null` when there's no previous bucket to compare against, or it was
  /// zero (a percentage change from zero is meaningless, not "infinite%").
  double? get changePct {
    final c = current;
    final p = previous;
    if (c == null || p == null || p.total == 0) return null;
    return (c.total - p.total) / p.total * 100;
  }

  factory DriverEarnings.fromJson(Map<String, dynamic> j) => DriverEarnings(
        period: (j['period'] as String?) ?? 'day',
        buckets: ((j['buckets'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(EarningsBucket.fromJson)
            .toList(),
      );
}

/// One side of a trip's counterpart identity — see `GET /v1/rides/{id}/participants`.
class TripPerson {
  const TripPerson({
    this.name,
    this.phone,
    this.rating,
    this.ratingCount = 0,
  });

  final String? name;

  /// Only populated while the trip is actively underway; `null` once it
  /// ends, so the dial button hides itself automatically.
  final String? phone;
  final double? rating;
  final int ratingCount;

  factory TripPerson.fromJson(Map<String, dynamic> j) => TripPerson(
        name: j['name'] as String?,
        phone: j['phone'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        ratingCount: (j['rating_count'] as num?)?.toInt() ?? 0,
      );
}

class TripDriverPerson extends TripPerson {
  const TripDriverPerson({
    super.name,
    super.phone,
    super.rating,
    super.ratingCount,
    this.vehicleClass,
    this.make,
    this.model,
    this.plateNumber,
    this.color,
    this.partnerName,
    this.photoUrl,
  });

  final String? vehicleClass;
  final String? make;
  final String? model;
  final String? plateNumber;
  final String? color;
  final String? partnerName;
  final String? photoUrl;

  String get vehicleLabel =>
      [make, model].where((s) => s != null && s.isNotEmpty).join(' ');

  factory TripDriverPerson.fromJson(Map<String, dynamic> j) => TripDriverPerson(
        name: j['name'] as String?,
        phone: j['phone'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        ratingCount: (j['rating_count'] as num?)?.toInt() ?? 0,
        vehicleClass: j['vehicle_class'] as String?,
        make: j['make'] as String?,
        model: j['model'] as String?,
        plateNumber: j['plate_number'] as String?,
        color: j['color'] as String?,
        partnerName: j['partner_name'] as String?,
        photoUrl: j['photo_url'] as String?,
      );
}

class TripParticipants {
  const TripParticipants({required this.rider, this.driver});

  final TripPerson rider;
  final TripDriverPerson? driver;

  factory TripParticipants.fromJson(Map<String, dynamic> j) => TripParticipants(
        rider: TripPerson.fromJson(j['rider'] as Map<String, dynamic>),
        driver: j['driver'] == null
            ? null
            : TripDriverPerson.fromJson(j['driver'] as Map<String, dynamic>),
      );
}

/// A driver's live bid against a rider's ask — `GET /v1/rides/{id}/bids`
/// (rider/staff only; blind bidding means a driver never sees this list).
class Bid {
  const Bid({
    required this.id,
    required this.driverId,
    required this.amount,
    required this.kind,
    required this.expiresAt,
    this.name,
    this.rating,
    this.ratingCount = 0,
    this.vehicleClass,
    this.make,
    this.model,
    this.plateNumber,
    this.partnerName,
    this.photoUrl,
  });

  final String id;
  final String driverId;
  final double amount;

  /// 'accept_ask' (matched the rider's price exactly) or 'counter'.
  final String kind;
  final DateTime expiresAt;
  final String? name;
  final double? rating;
  final int ratingCount;
  final String? vehicleClass;
  final String? make;
  final String? model;
  final String? plateNumber;
  final String? partnerName;
  final String? photoUrl;

  String get vehicleLabel =>
      [make, model].where((s) => s != null && s.isNotEmpty).join(' ');

  factory Bid.fromJson(Map<String, dynamic> j) => Bid(
        id: j['id'] as String,
        driverId: j['driver_id'] as String,
        amount: asDouble(j['amount']),
        kind: (j['kind'] as String?) ?? 'counter',
        expiresAt: DateTime.tryParse((j['expires_at'] as String?) ?? '') ??
            DateTime.now(),
        name: j['name'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        ratingCount: (j['rating_count'] as num?)?.toInt() ?? 0,
        vehicleClass: j['vehicle_class'] as String?,
        make: j['make'] as String?,
        model: j['model'] as String?,
        plateNumber: j['plate_number'] as String?,
        partnerName: j['partner_name'] as String?,
        photoUrl: j['photo_url'] as String?,
      );
}
