import '../../ride/domain/models.dart' show asDouble;

/// One overview slice (lifetime or "today") from
/// `GET /v1/merchant/merchants/{id}/analytics`.
class MerchantOverview {
  const MerchantOverview({
    required this.totalOrders,
    required this.deliveredOrders,
    required this.cancelledOrders,
    required this.totalRevenue,
    required this.avgOrderValue,
  });

  final int totalOrders;
  final int deliveredOrders;
  final int cancelledOrders;
  final double totalRevenue;
  final double avgOrderValue;

  factory MerchantOverview.fromJson(Map<String, dynamic> j) => MerchantOverview(
        totalOrders: (j['total_orders'] as num?)?.toInt() ?? 0,
        deliveredOrders: (j['delivered_orders'] as num?)?.toInt() ?? 0,
        cancelledOrders: (j['cancelled_orders'] as num?)?.toInt() ?? 0,
        totalRevenue: asDouble(j['total_revenue']),
        avgOrderValue: asDouble(j['avg_order_value']),
      );
}

class TopMenuItem {
  const TopMenuItem({
    required this.name,
    required this.units,
    required this.revenue,
  });

  final String name;
  final int units;
  final double revenue;

  factory TopMenuItem.fromJson(Map<String, dynamic> j) => TopMenuItem(
        name: (j['name'] as String?) ?? '',
        units: (j['units'] as num?)?.toInt() ?? 0,
        revenue: asDouble(j['revenue']),
      );
}

class RatingBucket {
  const RatingBucket({required this.stars, required this.count});
  final int stars;
  final int count;

  factory RatingBucket.fromJson(Map<String, dynamic> j) => RatingBucket(
        stars: (j['stars'] as num?)?.toInt() ?? 0,
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

class MerchantAnalytics {
  const MerchantAnalytics({
    required this.overview,
    required this.today,
    required this.topItems,
    required this.ratingBreakdown,
  });

  final MerchantOverview overview;
  final MerchantOverview today;
  final List<TopMenuItem> topItems;
  final List<RatingBucket> ratingBreakdown;

  factory MerchantAnalytics.fromJson(Map<String, dynamic> j) => MerchantAnalytics(
        overview: MerchantOverview.fromJson(j['overview'] as Map<String, dynamic>),
        today: MerchantOverview.fromJson(j['today'] as Map<String, dynamic>),
        topItems: ((j['top_items'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(TopMenuItem.fromJson)
            .toList(),
        ratingBreakdown: ((j['rating_breakdown'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(RatingBucket.fromJson)
            .toList(),
      );
}

/// A store-owned promotion — free delivery, or a %/flat discount, over a
/// minimum order amount, optionally boxed to a date range and/or a daily
/// time-of-day window. Auto-applied at checkout, no code needed.
class MerchantOffer {
  const MerchantOffer({
    required this.id,
    required this.kind,
    this.value,
    this.maxDiscount,
    required this.minOrderAmount,
    this.startsAt,
    this.endsAt,
    this.dailyStartMinute,
    this.dailyEndMinute,
    required this.active,
  });

  final String id;
  final String kind; // free_delivery | percent | flat
  final double? value;
  final double? maxDiscount;
  final double minOrderAmount;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int? dailyStartMinute;
  final int? dailyEndMinute;
  final bool active;

  /// A short, human-readable line for a customer-facing banner, e.g.
  /// "Free delivery over NPR 500" or "10% off orders over NPR 300".
  String get summaryLine {
    final min = minOrderAmount > 0
        ? ' over NPR ${minOrderAmount.toStringAsFixed(0)}'
        : '';
    switch (kind) {
      case 'free_delivery':
        return 'Free delivery$min';
      case 'percent':
        final cap = maxDiscount;
        final capText =
            cap == null ? '' : ' (up to NPR ${cap.toStringAsFixed(0)})';
        return '${value?.toStringAsFixed(0) ?? 0}% off orders$min$capText';
      default:
        return 'NPR ${value?.toStringAsFixed(0) ?? 0} off orders$min';
    }
  }

  factory MerchantOffer.fromJson(Map<String, dynamic> j) => MerchantOffer(
        id: j['id'] as String,
        kind: (j['kind'] as String?) ?? 'flat',
        value: j['value'] == null ? null : asDouble(j['value']),
        maxDiscount:
            j['max_discount'] == null ? null : asDouble(j['max_discount']),
        minOrderAmount: asDouble(j['min_order_amount']),
        startsAt: j['starts_at'] == null
            ? null
            : DateTime.tryParse(j['starts_at'] as String),
        endsAt: j['ends_at'] == null
            ? null
            : DateTime.tryParse(j['ends_at'] as String),
        dailyStartMinute: (j['daily_start_minute'] as num?)?.toInt(),
        dailyEndMinute: (j['daily_end_minute'] as num?)?.toInt(),
        active: (j['active'] as bool?) ?? true,
      );
}
