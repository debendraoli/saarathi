import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../domain/models.dart';

/// Auth endpoints on the gateway. OTP dev-mode echoes the code back so we can
/// log in without an SMS gateway (backend OTP_DEV_MODE=true).
class AuthRepository {
  AuthRepository(this._api);

  final ApiClient _api;

  /// Returns the dev code when the backend is in OTP dev mode, else null.
  Future<String?> requestOtp(String phone) async {
    final res = await _api.post('/v1/auth/otp/request', body: {'phone': phone});
    final map = res as Map<String, dynamic>;
    return map['dev_code'] as String?;
  }

  Future<Session> verifyOtp(String phone, String code, {bool asDriver = false}) async {
    final res = await _api.post('/v1/auth/otp/verify', body: {
      'phone': phone,
      'code': code,
      'as_driver': asDriver,
    });
    return Session.fromJson(res as Map<String, dynamic>);
  }

  Future<AppUser> me() async {
    final res = await _api.get('/v1/me');
    return AppUser.fromJson(res as Map<String, dynamic>);
  }

  Future<AppUser> updateName(String fullName) async {
    final res = await _api.put('/v1/me', body: {'full_name': fullName});
    return AppUser.fromJson(res as Map<String, dynamic>);
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(ref.watch(apiClientProvider));
});
