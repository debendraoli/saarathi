import 'package:latlong2/latlong.dart';

import '../../../shared/image_url.dart';
import '../../ride/domain/models.dart' show asDouble;

// Marketplace domain models (shared by customer + merchant surfaces).
class Merchant {
  const Merchant({
    required this.id,
    required this.name,
    required this.vertical,
    required this.point,
    required this.prepMins,
    required this.isOpen,
    required this.rating,
    this.address,
    this.phone,
    this.distanceKm,
    this.imageKey,
    this.status = 'approved',
    this.rejectionReason,
  });

  final String id;
  final String name;
  final String vertical;
  final LatLng point;
  final int prepMins;
  final bool isOpen;
  final double rating;
  final String? address;
  final String? phone;
  final double? distanceKm;
  final String? imageKey;

  /// Staff approval state: 'pending' | 'approved' | 'rejected'. Defaults to
  /// 'approved' since customer-facing discovery endpoints only ever return
  /// approved stores anyway — only the owner's own `my_merchants` view can
  /// see a pending/rejected one.
  final String status;
  final String? rejectionReason;

  bool get isApproved => status == 'approved';
  bool get isPending => status == 'pending';
  bool get isRejected => status == 'rejected';

  String? get imageUrl => asImageUrl(imageKey);

  factory Merchant.fromJson(Map<String, dynamic> j) => Merchant(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        vertical: (j['vertical'] as String?) ?? 'food',
        point: LatLng(asDouble(j['lat']), asDouble(j['lng'])),
        prepMins: (j['prep_mins'] as num?)?.toInt() ?? 20,
        isOpen: (j['is_open'] as bool?) ?? true,
        rating: asDouble(j['rating']),
        address: j['address'] as String?,
        phone: j['phone'] as String?,
        distanceKm:
            j['distance_m'] == null ? null : asDouble(j['distance_m']) / 1000.0,
        imageKey: j['image_key'] as String?,
        status: (j['status'] as String?) ?? 'approved',
        rejectionReason: j['rejection_reason'] as String?,
      );
}

/// One merchant's active offer, surfaced across the whole vertical (not
/// scoped to a single store) — `GET /v1/offers/nearby`. Backs the "Offers
/// near you" carousel on the browse screen; distinct from [MenuItem]'s
/// per-store `storeOffersProvider`, which only fires once a merchant is
/// already open.
class NearbyOffer {
  const NearbyOffer({
    required this.id,
    required this.merchantId,
    required this.merchantName,
    required this.vertical,
    this.imageKey,
    required this.kind,
    this.value,
    this.maxDiscount,
    required this.minOrderAmount,
    this.distanceKm,
  });

  final String id;
  final String merchantId;
  final String merchantName;
  final String vertical;
  final String? imageKey;
  final String kind; // free_delivery | percent | flat
  final double? value;
  final double? maxDiscount;
  final double minOrderAmount;
  final double? distanceKm;

  String? get imageUrl => asImageUrl(imageKey);

  /// Short ribbon/badge text, e.g. "40% OFF", "Free delivery", "Rs 100 OFF".
  String get badgeText {
    switch (kind) {
      case 'free_delivery':
        return 'Free delivery';
      case 'percent':
        return '${value?.toStringAsFixed(0) ?? 0}% OFF';
      default:
        return 'Rs ${value?.toStringAsFixed(0) ?? 0} OFF';
    }
  }

  /// A short qualifier under the badge, e.g. "Up to NPR 150" or "Orders over
  /// NPR 300" — empty when the offer has neither a cap nor a minimum.
  String get qualifier {
    if (maxDiscount != null) {
      return 'Up to NPR ${maxDiscount!.toStringAsFixed(0)}';
    }
    if (minOrderAmount > 0) {
      return 'Orders over NPR ${minOrderAmount.toStringAsFixed(0)}';
    }
    return '';
  }

  factory NearbyOffer.fromJson(Map<String, dynamic> j) => NearbyOffer(
        id: j['id'] as String,
        merchantId: j['merchant_id'] as String,
        merchantName: (j['merchant_name'] as String?) ?? '',
        vertical: (j['vertical'] as String?) ?? 'food',
        imageKey: j['image_key'] as String?,
        kind: (j['kind'] as String?) ?? 'flat',
        value: j['value'] == null ? null : asDouble(j['value']),
        maxDiscount:
            j['max_discount'] == null ? null : asDouble(j['max_discount']),
        minOrderAmount: asDouble(j['min_order_amount']),
        distanceKm:
            j['distance_m'] == null ? null : asDouble(j['distance_m']) / 1000.0,
      );
}

class MenuItem {
  const MenuItem({
    required this.id,
    required this.name,
    required this.price,
    this.description,
    this.category,
    this.merchantId,
    this.isAvailable = true,
    this.imageUrl,
  });

  final String id;
  final String name;
  final double price;
  final String? description;
  final String? category;
  final String? merchantId;
  final bool isAvailable;
  final String? imageUrl;

  factory MenuItem.fromJson(Map<String, dynamic> j) => MenuItem(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        price: asDouble(j['price']),
        description: j['description'] as String?,
        category: j['category'] as String?,
        merchantId: j['merchant_id'] as String?,
        isAvailable: (j['is_available'] as bool?) ?? true,
        imageUrl: asImageUrl(j['image_key']),
      );
}

/// A cross-merchant item search hit (item + its merchant + distance).
class ItemResult {
  const ItemResult({
    required this.id,
    required this.merchantId,
    required this.merchantName,
    required this.vertical,
    required this.name,
    required this.price,
    required this.rating,
    this.description,
    this.imageUrl,
    this.distanceKm,
  });

  final String id;
  final String merchantId;
  final String merchantName;
  final String vertical;
  final String name;
  final double price;
  final double rating;
  final String? description;
  final String? imageUrl;
  final double? distanceKm;

  factory ItemResult.fromJson(Map<String, dynamic> j) => ItemResult(
        id: j['id'] as String,
        merchantId: j['merchant_id'] as String,
        merchantName: (j['merchant_name'] as String?) ?? '',
        vertical: (j['vertical'] as String?) ?? 'food',
        name: (j['name'] as String?) ?? '',
        price: asDouble(j['price']),
        rating: asDouble(j['rating']),
        description: j['description'] as String?,
        imageUrl: asImageUrl(j['image_key']),
        distanceKm:
            j['distance_m'] == null ? null : asDouble(j['distance_m']) / 1000.0,
      );
}

class OrderItem {
  const OrderItem(
      {required this.name, required this.unitPrice, required this.qty});
  final String name;
  final double unitPrice;
  final int qty;

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        name: (j['name'] as String?) ?? '',
        unitPrice: asDouble(j['unit_price']),
        qty: (j['qty'] as num?)?.toInt() ?? 1,
      );
}

/// Self-service lifetime order-spend rollup — `GET /v1/orders/mine/stats`.
class OrderStats {
  const OrderStats({
    required this.totalOrders,
    required this.deliveredOrders,
    required this.totalSpent,
  });

  final int totalOrders;
  final int deliveredOrders;
  final double totalSpent;

  factory OrderStats.fromJson(Map<String, dynamic> j) => OrderStats(
        totalOrders: (j['total_orders'] as num?)?.toInt() ?? 0,
        deliveredOrders: (j['delivered_orders'] as num?)?.toInt() ?? 0,
        totalSpent: asDouble(j['total_spent']),
      );
}

class CustomerOrder {
  const CustomerOrder({
    required this.id,
    required this.merchantName,
    required this.status,
    required this.subtotal,
    required this.deliveryFee,
    required this.total,
    this.merchantId,
    this.tripId,
    this.items = const [],
    this.createdAt,
    this.rated = false,
    this.merchantRated = false,
    this.discountAmount = 0,
  });

  final String id;
  final String merchantName;
  final String status;
  final double subtotal;
  final double deliveryFee;
  final double total;

  /// Savings from an auto-applied store offer, if any (0 when none applied).
  final double discountAmount;
  final String? merchantId;
  final String? tripId;
  final List<OrderItem> items;
  final DateTime? createdAt;

  /// Whether the signed-in customer has already rated this order's courier
  /// (only meaningful once `tripId` is set — a courier's been dispatched).
  final bool rated;

  /// Whether the signed-in customer has already rated the merchant itself —
  /// meaningful for every delivered order, regardless of courier dispatch.
  final bool merchantRated;

  bool get isActive => !const {
        'delivered',
        'cancelled',
        'rejected',
      }.contains(status);

  factory CustomerOrder.fromJson(Map<String, dynamic> j,
          {List<OrderItem> items = const []}) =>
      CustomerOrder(
        id: j['id'] as String,
        merchantName: (j['merchant_name'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'placed',
        subtotal: asDouble(j['subtotal']),
        deliveryFee: asDouble(j['delivery_fee']),
        total: asDouble(j['total']),
        merchantId: j['merchant_id'] as String?,
        tripId: j['trip_id'] as String?,
        items: items,
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
        rated: (j['rated'] as bool?) ?? false,
        merchantRated: (j['merchant_rated'] as bool?) ?? false,
        discountAmount: asDouble(j['discount_amount']),
      );
}
