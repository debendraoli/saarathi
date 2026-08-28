import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/provider_retry.dart';
import '../../ride/domain/models.dart';
import '../domain/models.dart';

class DriverInput {
  const DriverInput({
    required this.vehicleClass,
    required this.plateNumber,
    this.licenseNumber,
    this.dateOfBirth,
    this.address,
    this.make,
    this.model,
    this.serviceTypes = const {'ride'},
  });

  final VehicleClass vehicleClass;
  final String plateNumber;
  final String? licenseNumber;
  final String? dateOfBirth; // YYYY-MM-DD
  final String? address;
  final String? make;
  final String? model;

  /// "ride", "delivery", or both — see [DriverKyc.serviceTypes].
  final Set<String> serviceTypes;
}

class DriverKycRepository {
  DriverKycRepository(this._api);

  final ApiClient _api;

  Future<void> register(DriverInput input) => _api.post(
        '/v1/driver/register',
        body: {
          if (input.licenseNumber != null)
            'license_number': input.licenseNumber,
          if (input.dateOfBirth != null) 'date_of_birth': input.dateOfBirth,
          if (input.address != null) 'address': input.address,
          'vehicle': {
            'class': input.vehicleClass.wire,
            'plate_number': input.plateNumber,
            if (input.make != null) 'make': input.make,
            if (input.model != null) 'model': input.model,
          },
          'service_types': input.serviceTypes.toList(),
        },
      );

  Future<void> uploadDocument(String kind, String filePath) async {
    final form = FormData.fromMap({
      'kind': kind,
      'file': await MultipartFile.fromFile(filePath),
    });
    await _api.upload('/v1/driver/documents', form);
  }

  Future<DriverKyc> status() async {
    final res = await _api.get('/v1/driver/status');
    return DriverKyc.fromJson(res as Map<String, dynamic>);
  }

  /// Gated server-side on every [DocKind] being uploaded; moves the driver
  /// from `pending` (not yet in the staff queue) to `under_review`.
  Future<void> submit() => _api.post('/v1/driver/kyc/submit');
}

final driverKycRepositoryProvider = Provider<DriverKycRepository>((ref) {
  return DriverKycRepository(ref.watch(apiClientProvider));
});

/// Current driver verification snapshot (refresh after each upload).
final driverKycProvider = FutureProvider.autoDispose<DriverKyc>((ref) {
  return ref.watch(driverKycRepositoryProvider).status();
}, retry: shortNetworkRetry);
