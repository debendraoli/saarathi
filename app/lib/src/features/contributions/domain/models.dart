import 'package:latlong2/latlong.dart';

enum ContributionCategory {
  organisation,
  building,
  landmark,
  construction,
  closedRoad,
  sign,
  other;

  String get wire => switch (this) {
        ContributionCategory.organisation => 'organisation',
        ContributionCategory.building => 'building',
        ContributionCategory.landmark => 'landmark',
        ContributionCategory.construction => 'construction',
        ContributionCategory.closedRoad => 'closed_road',
        ContributionCategory.sign => 'sign',
        ContributionCategory.other => 'other',
      };
}

class PlaceContribution {
  const PlaceContribution({
    required this.id,
    required this.category,
    required this.name,
    required this.description,
    required this.point,
    required this.status,
    required this.rejectionReason,
    required this.pointsAwarded,
    required this.createdAt,
  });

  final String id;
  final String category;
  final String name;
  final String? description;
  final LatLng point;
  final String status; // pending | approved | rejected
  final String? rejectionReason;
  final int? pointsAwarded;
  final DateTime createdAt;

  factory PlaceContribution.fromJson(Map<String, dynamic> j) =>
      PlaceContribution(
        id: j['id'] as String,
        category: j['category'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        point:
            LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        status: j['status'] as String,
        rejectionReason: j['rejection_reason'] as String?,
        pointsAwarded: (j['points_awarded'] as num?)?.toInt(),
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

class ContributorBadge {
  const ContributorBadge(
      {required this.code, required this.title, required this.awardedAt});
  final String code;
  final String title;
  final DateTime awardedAt;

  factory ContributorBadge.fromJson(Map<String, dynamic> j) => ContributorBadge(
        code: j['code'] as String,
        title: j['title'] as String,
        awardedAt: DateTime.parse(j['awarded_at'] as String),
      );
}

class PointsSummary {
  const PointsSummary({
    required this.balance,
    required this.badges,
    required this.minRedeemPoints,
    required this.pointsToNprRate,
  });

  final int balance;
  final List<ContributorBadge> badges;
  final int minRedeemPoints;
  final int pointsToNprRate;

  factory PointsSummary.fromJson(Map<String, dynamic> j) => PointsSummary(
        balance: (j['balance'] as num).toInt(),
        badges: (j['badges'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ContributorBadge.fromJson)
            .toList(),
        minRedeemPoints: (j['min_redeem_points'] as num).toInt(),
        pointsToNprRate: (j['points_to_npr_rate'] as num).toInt(),
      );
}
