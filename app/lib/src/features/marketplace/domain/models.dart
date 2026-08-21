import 'package:latlong2/latlong.dart';

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
        imageUrl: _asImageUrl(j['image_key']),
      );
}

/// Treats an `image_key` that is already an absolute URL as the image source.
/// (Object-storage keys would be resolved against a media base later.)
String? _asImageUrl(Object? key) {
  final s = key as String?;
  if (s == null || s.isEmpty) return null;
  return s.startsWith('http') ? s : null;
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
        imageUrl: _asImageUrl(j['image_key']),
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
  });

  final String id;
  final String merchantName;
  final String status;
  final double subtotal;
  final double deliveryFee;
  final double total;
  final String? merchantId;
  final String? tripId;
  final List<OrderItem> items;
  final DateTime? createdAt;

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
      );
}
