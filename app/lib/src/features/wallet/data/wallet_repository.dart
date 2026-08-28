import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/provider_retry.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../domain/models.dart';

/// Rider prepaid credits live on `saarathi-payments` (`/v1/credits*`); driver
/// prepaid credits live on `saarathi-rides` (`/v1/driver/credits*`) since
/// they fund the per-ride commission draw there. Top-up confirmation is one
/// shared endpoint on payments — it looks up which kind a reference belongs
/// to itself, so the client doesn't need to know or pass it.
class WalletRepository {
  WalletRepository(this._api, {required this.isDriver});

  final ApiClient _api;
  final bool isDriver;

  String get _balancePath => isDriver ? '/v1/driver/credits' : '/v1/credits';
  String get _topupPath =>
      isDriver ? '/v1/driver/credits/topup' : '/v1/credits/topup';

  Future<WalletBalance> balance() async {
    final res = await _api.get(_balancePath) as Map<String, dynamic>;
    return WalletBalance.fromJson(res);
  }

  Future<TopupIntent> topup(double amount) async {
    final res = await _api.post(
      _topupPath,
      headers: {'x-idempotency-key': newIdempotencyKey()},
      body: {'amount': amount},
    ) as Map<String, dynamic>;
    return TopupIntent.fromJson(res);
  }

  /// Always safe to call speculatively — the server re-verifies with the
  /// payment provider itself and never trusts this call's timing, so it's
  /// fine to hit this the moment the user returns to the app.
  Future<TopupResult> confirmTopup(String reference) async {
    try {
      final res = await _api.post(
        '/v1/credits/topup/confirm',
        body: {'reference': reference},
      ) as Map<String, dynamic>;
      return TopupResult.fromJson(res);
    } on ApiException catch (e) {
      if (e.isNetwork) rethrow;
      return const TopupResult(TopupStatus.failed);
    }
  }
}

final walletRepositoryProvider = Provider.family<WalletRepository, bool>(
  (ref, isDriver) =>
      WalletRepository(ref.watch(apiClientProvider), isDriver: isDriver),
);

/// Repository for the *current* mode (rider vs driver), so screens don't
/// need to thread `isDriver` through themselves.
final currentWalletRepositoryProvider = Provider<WalletRepository>((ref) {
  final isDriver = ref.watch(authControllerProvider).mode == AppMode.driver;
  return ref.watch(walletRepositoryProvider(isDriver));
});

final walletBalanceProvider = FutureProvider.autoDispose<WalletBalance>((ref) {
  return ref.watch(currentWalletRepositoryProvider).balance();
}, retry: shortNetworkRetry);
