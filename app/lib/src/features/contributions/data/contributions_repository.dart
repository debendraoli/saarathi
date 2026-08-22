import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/network/api_client.dart';
import '../domain/models.dart';

class ContributionSubmission {
  const ContributionSubmission({
    required this.category,
    required this.name,
    this.description,
    required this.point,
    required this.capturePoint,
    required this.photoPath,
  });

  final ContributionCategory category;
  final String name;
  final String? description;
  final LatLng point;
  final LatLng capturePoint;
  final String photoPath;
}

class ContributionsRepository {
  ContributionsRepository(this._api);
  final ApiClient _api;

  Future<PlaceContribution> submit(ContributionSubmission s) async {
    final form = FormData.fromMap({
      'category': s.category.wire,
      'name': s.name,
      if (s.description != null && s.description!.isNotEmpty) 'description': s.description,
      'lat': s.point.latitude.toString(),
      'lng': s.point.longitude.toString(),
      'capture_lat': s.capturePoint.latitude.toString(),
      'capture_lng': s.capturePoint.longitude.toString(),
      'photo': await MultipartFile.fromFile(s.photoPath),
    });
    final res = await _api.upload('/v1/places/contributions', form);
    return PlaceContribution.fromJson(res as Map<String, dynamic>);
  }

  Future<List<PlaceContribution>> mine() async {
    final res = await _api.get('/v1/places/contributions/mine') as Map<String, dynamic>;
    return (res['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(PlaceContribution.fromJson)
        .toList();
  }

  Future<PointsSummary> points() async {
    final res = await _api.get('/v1/places/points') as Map<String, dynamic>;
    return PointsSummary.fromJson(res);
  }

  Future<double> redeem(int points) async {
    final res = await _api.post(
      '/v1/places/points/redeem',
      body: {'points': points},
    ) as Map<String, dynamic>;
    return (res['wallet_balance'] as num).toDouble();
  }
}

final contributionsRepositoryProvider = Provider<ContributionsRepository>((ref) {
  return ContributionsRepository(ref.watch(apiClientProvider));
});

final myContributionsProvider =
    FutureProvider.autoDispose<List<PlaceContribution>>((ref) {
  return ref.watch(contributionsRepositoryProvider).mine();
});

final pointsSummaryProvider = FutureProvider.autoDispose<PointsSummary>((ref) {
  return ref.watch(contributionsRepositoryProvider).points();
});
